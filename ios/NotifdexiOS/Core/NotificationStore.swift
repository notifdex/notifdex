import Foundation
import SQLite3

/// Durable SQLite repository for iOS-captured notifications, settings, and intent telemetry.
/// Schema is aligned with NotifdexCore's `observations` columns so Phase 2 sync drops in cleanly.
public final class NotificationStore: @unchecked Sendable {
    public let databaseURL: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let queue = DispatchQueue(label: "com.notifdex.ios.notification-store")

    private static let settingsKey = "capture_settings_v1"

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.applyBackgroundFriendlyProtection(to: directory)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database"
            sqlite3_close(db)
            db = nil
            throw CaptureStoreError(message)
        }
        Self.applyBackgroundFriendlyProtection(to: databaseURL)

        do {
            sqlite3_busy_timeout(db, 3000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try migrateIfNeeded()
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private static func applyBackgroundFriendlyProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func migrateIfNeeded() throws {
        let version = try scalarInt("PRAGMA user_version")
        guard (0...1).contains(version) else {
            throw CaptureStoreError("Unsupported iOS capture database version \(version)")
        }
        if version == 0 {
            try transaction {
                try execute("""
                CREATE TABLE IF NOT EXISTS captured_notifications (
                    id INTEGER PRIMARY KEY,
                    capture_uuid TEXT NOT NULL UNIQUE,
                    source_id TEXT NOT NULL CHECK (length(source_id) > 0),
                    source_event_id TEXT NOT NULL CHECK (length(source_event_id) > 0),
                    capture_channel TEXT NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('iphone', 'mac', 'unknown')),
                    app_label TEXT NOT NULL CHECK (length(app_label) > 0),
                    title TEXT NOT NULL,
                    subtitle TEXT NOT NULL,
                    body TEXT NOT NULL,
                    captured_at REAL NOT NULL,
                    device_id TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    UNIQUE (source_id, source_event_id)
                );
                CREATE INDEX IF NOT EXISTS idx_captured_notifications_time
                    ON captured_notifications(captured_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS idx_captured_notifications_app
                    ON captured_notifications(app_label, captured_at DESC);

                CREATE TABLE IF NOT EXISTS kv_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS intent_execution_logs (
                    id INTEGER PRIMARY KEY,
                    timestamp REAL NOT NULL,
                    app_label TEXT NOT NULL,
                    outcome TEXT NOT NULL,
                    detail TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_intent_logs_time
                    ON intent_execution_logs(timestamp DESC, id DESC);
                """)
                try execute("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: - Settings

    public func loadOrCreateSettings(defaultDeviceID: String = UUID().uuidString) throws -> CaptureSettingsState {
        try queue.sync {
            if let raw = try fetchSettingRaw(key: Self.settingsKey),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(CaptureSettingsState.self, from: data) {
                return decoded
            }
            let created = CaptureSettingsState(deviceID: defaultDeviceID)
            try saveSettingsLocked(created)
            return created
        }
    }

    public func saveSettings(_ settings: CaptureSettingsState) throws {
        try queue.sync {
            try saveSettingsLocked(settings)
        }
    }

    public func markAppVerified(_ appLabel: String) throws -> CaptureSettingsState {
        try queue.sync {
            let normalized = CaptureNormalizer.normalizeAppLabel(appLabel)
            var state: CaptureSettingsState
            if let raw = try fetchSettingRaw(key: Self.settingsKey),
               let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(CaptureSettingsState.self, from: data) {
                state = decoded
            } else {
                state = CaptureSettingsState(deviceID: UUID().uuidString)
            }
            guard !normalized.isEmpty else { return state }
            if !state.verifiedAppLabels.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                state.verifiedAppLabels.append(normalized)
                try saveSettingsLocked(state)
            }
            return state
        }
    }

    private func fetchSettingRaw(key: String) throws -> String? {
        let sql = "SELECT value FROM kv_settings WHERE key = ? LIMIT 1"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: key)
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW {
            return columnText(stmt, index: 0)
        }
        if rc != SQLITE_DONE {
            throw lastError()
        }
        return nil
    }

    private func saveSettingsLocked(_ settings: CaptureSettingsState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CaptureStoreError("Failed to encode settings")
        }
        try transaction {
            let stmt = try prepare("""
                INSERT INTO kv_settings(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, index: 1, value: Self.settingsKey)
            bindText(stmt, index: 2, value: json)
            try stepDone(stmt)
        }
    }

    // MARK: - Notifications

    public func insertNotification(
        _ normalized: NormalizedNotification,
        sourceID: String,
        deviceID: String,
        dedupWindowSeconds: Double = CaptureNormalizer.dedupBucketSeconds
    ) throws -> (record: CapturedNotification, inserted: Bool) {
        try queue.sync {
            guard normalized.capturedAt.isFinite else {
                throw CaptureStoreError("Invalid capture timestamp")
            }
            var resultRecord: CapturedNotification?
            var wasInserted = false

            try transaction {
                // Sliding-window deduplication avoids clock-boundary misses (e.g. :59 -> :01 retries).
                if dedupWindowSeconds > 0 {
                    let existingStmt = try prepare("""
                        SELECT id, capture_uuid, source_id, source_event_id, capture_channel, origin,
                               app_label, title, subtitle, body, captured_at, device_id, metadata_json
                        FROM captured_notifications
                        WHERE source_id = ?
                          AND lower(app_label) = lower(?)
                          AND title = ?
                          AND subtitle = ?
                          AND body = ?
                          AND abs(captured_at - ?) <= ?
                        ORDER BY captured_at DESC, id DESC
                        LIMIT 1
                        """)
                    defer { sqlite3_finalize(existingStmt) }
                    bindText(existingStmt, index: 1, value: sourceID)
                    bindText(existingStmt, index: 2, value: normalized.appLabel)
                    bindText(existingStmt, index: 3, value: normalized.title)
                    bindText(existingStmt, index: 4, value: normalized.subtitle)
                    bindText(existingStmt, index: 5, value: normalized.body)
                    sqlite3_bind_double(existingStmt, 6, normalized.capturedAt)
                    sqlite3_bind_double(existingStmt, 7, dedupWindowSeconds)

                    if sqlite3_step(existingStmt) == SQLITE_ROW {
                        resultRecord = readNotificationRow(existingStmt)
                        wasInserted = false
                        return
                    }
                }

                let captureUUID = UUID().uuidString
                let insertStmt = try prepare("""
                    INSERT OR IGNORE INTO captured_notifications
                    (capture_uuid, source_id, source_event_id, capture_channel, origin,
                     app_label, title, subtitle, body, captured_at, device_id, metadata_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(insertStmt) }

                bindText(insertStmt, index: 1, value: captureUUID)
                bindText(insertStmt, index: 2, value: sourceID)
                bindText(insertStmt, index: 3, value: normalized.dedupKey)
                bindText(insertStmt, index: 4, value: normalized.channel.rawValue)
                bindText(insertStmt, index: 5, value: normalized.origin.rawValue)
                bindText(insertStmt, index: 6, value: normalized.appLabel)
                bindText(insertStmt, index: 7, value: normalized.title)
                bindText(insertStmt, index: 8, value: normalized.subtitle)
                bindText(insertStmt, index: 9, value: normalized.body)
                sqlite3_bind_double(insertStmt, 10, normalized.capturedAt)
                bindText(insertStmt, index: 11, value: deviceID)
                bindText(insertStmt, index: 12, value: normalized.metadataJSON)

                try stepDone(insertStmt)
                wasInserted = sqlite3_changes(db) > 0

                let fetchStmt = try prepare("""
                    SELECT id, capture_uuid, source_id, source_event_id, capture_channel, origin,
                           app_label, title, subtitle, body, captured_at, device_id, metadata_json
                    FROM captured_notifications
                    WHERE source_id = ? AND source_event_id = ?
                    LIMIT 1
                    """)
                defer { sqlite3_finalize(fetchStmt) }
                bindText(fetchStmt, index: 1, value: sourceID)
                bindText(fetchStmt, index: 2, value: normalized.dedupKey)

                if sqlite3_step(fetchStmt) == SQLITE_ROW {
                    resultRecord = readNotificationRow(fetchStmt)
                } else {
                    throw CaptureStoreError("Failed to reload committed notification")
                }
            }

            guard let record = resultRecord else {
                throw CaptureStoreError("Missing notification record after commit")
            }
            return (record, wasInserted)
        }
    }

    public func fetchNotifications(
        appFilter: String? = nil,
        searchText: String = "",
        limit: Int = 200
    ) throws -> [CapturedNotification] {
        try queue.sync {
            var clauses: [String] = []
            var bindings: [String] = []

            if let appFilter {
                let cleaned = CaptureNormalizer.normalizeAppLabel(appFilter)
                if !cleaned.isEmpty {
                    clauses.append("lower(app_label) = lower(?)")
                    bindings.append(cleaned)
                }
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                let escaped = query
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern = "%\(escaped)%"
                clauses.append("""
                    (app_label LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
                     OR subtitle LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\')
                    """)
                bindings.append(contentsOf: [pattern, pattern, pattern, pattern])
            }

            let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
            let sql = """
                SELECT id, capture_uuid, source_id, source_event_id, capture_channel, origin,
                       app_label, title, subtitle, body, captured_at, device_id, metadata_json
                FROM captured_notifications
                \(whereSQL)
                ORDER BY captured_at DESC, id DESC
                LIMIT ?
                """

            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for (idx, value) in bindings.enumerated() {
                bindText(stmt, index: Int32(idx + 1), value: value)
            }
            sqlite3_bind_int(stmt, Int32(bindings.count + 1), Int32(max(1, limit)))

            var results: [CapturedNotification] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    results.append(readNotificationRow(stmt))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw lastError()
                }
            }
            return results
        }
    }

    public func stats() throws -> CaptureStats {
        try queue.sync {
            let totalStmt = try prepare("SELECT count(*), max(captured_at) FROM captured_notifications")
            defer { sqlite3_finalize(totalStmt) }
            var total = 0
            var lastAt: Double?
            if sqlite3_step(totalStmt) == SQLITE_ROW {
                total = Int(sqlite3_column_int64(totalStmt, 0))
                if sqlite3_column_type(totalStmt, 1) != SQLITE_NULL {
                    lastAt = sqlite3_column_double(totalStmt, 1)
                }
            }

            let appStmt = try prepare("""
                SELECT app_label, count(*), max(captured_at)
                FROM captured_notifications
                GROUP BY app_label
                """)
            defer { sqlite3_finalize(appStmt) }
            var counts: [String: Int] = [:]
            var lasts: [String: Double] = [:]
            while sqlite3_step(appStmt) == SQLITE_ROW {
                let app = columnText(appStmt, index: 0)
                counts[app] = Int(sqlite3_column_int64(appStmt, 1))
                lasts[app] = sqlite3_column_double(appStmt, 2)
            }

            return CaptureStats(
                totalCount: total,
                lastCapturedAt: lastAt,
                countByApp: counts,
                lastCapturedByApp: lasts
            )
        }
    }

    public func clearAllNotifications() throws {
        try queue.sync {
            try transaction {
                try execute("DELETE FROM captured_notifications")
            }
        }
    }

    // MARK: - Execution Telemetry

    public func recordExecutionLog(appLabel: String, outcome: String, detail: String, at timestamp: Double) throws {
        try queue.sync {
            try transaction {
                let stmt = try prepare("""
                    INSERT INTO intent_execution_logs(timestamp, app_label, outcome, detail)
                    VALUES (?, ?, ?, ?)
                    """)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_double(stmt, 1, timestamp)
                bindText(stmt, index: 2, value: appLabel)
                bindText(stmt, index: 3, value: outcome)
                bindText(stmt, index: 4, value: detail)
                try stepDone(stmt)

                // Keep debug telemetry bounded to the latest 200 entries.
                try execute("""
                    DELETE FROM intent_execution_logs
                    WHERE id NOT IN (
                        SELECT id FROM intent_execution_logs ORDER BY id DESC LIMIT 200
                    )
                    """)
            }
        }
    }

    public func fetchExecutionLogs(limit: Int = 50) throws -> [IntentExecutionLogEntry] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, timestamp, app_label, outcome, detail
                FROM intent_execution_logs
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
                """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(max(1, limit)))

            var logs: [IntentExecutionLogEntry] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    logs.append(IntentExecutionLogEntry(
                        id: sqlite3_column_int64(stmt, 0),
                        timestamp: sqlite3_column_double(stmt, 1),
                        appLabel: columnText(stmt, index: 2),
                        outcome: columnText(stmt, index: 3),
                        detail: columnText(stmt, index: 4)
                    ))
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw lastError()
                }
            }
            return logs
        }
    }

    // MARK: - SQLite Helpers

    private func readNotificationRow(_ stmt: OpaquePointer?) -> CapturedNotification {
        let channelRaw = columnText(stmt, index: 4)
        let originRaw = columnText(stmt, index: 5)
        return CapturedNotification(
            id: sqlite3_column_int64(stmt, 0),
            captureUUID: columnText(stmt, index: 1),
            sourceID: columnText(stmt, index: 2),
            sourceEventID: columnText(stmt, index: 3),
            captureChannel: CaptureChannel(rawValue: channelRaw) ?? .iosShortcuts,
            origin: NotificationOrigin(rawValue: originRaw) ?? .iphone,
            appLabel: columnText(stmt, index: 6),
            title: columnText(stmt, index: 7),
            subtitle: columnText(stmt, index: 8),
            body: columnText(stmt, index: 9),
            capturedAt: sqlite3_column_double(stmt, 10),
            deviceID: columnText(stmt, index: 11),
            metadataJSON: columnText(stmt, index: 12)
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError().message
            sqlite3_free(errorMessage)
            throw CaptureStoreError(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        let utf8 = Array(value.utf8)
        if utf8.isEmpty {
            sqlite3_bind_text(stmt, index, "", 0, transient)
        } else {
            utf8.withUnsafeBytes { raw in
                sqlite3_bind_text(stmt, index, raw.bindMemory(to: CChar.self).baseAddress, Int32(utf8.count), transient)
            }
        }
    }

    private func columnText(_ stmt: OpaquePointer?, index: Int32) -> String {
        guard let bytes = sqlite3_column_text(stmt, index) else { return "" }
        let length = Int(sqlite3_column_bytes(stmt, index))
        let buffer = UnsafeBufferPointer(start: bytes, count: length)
        return String(decoding: buffer, as: UTF8.self)
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw lastError()
        }
    }

    private func scalarInt(_ sql: String) throws -> Int64 {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw lastError()
        }
        return sqlite3_column_int64(stmt, 0)
    }

    private func lastError() -> CaptureStoreError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return CaptureStoreError(message)
    }
}
