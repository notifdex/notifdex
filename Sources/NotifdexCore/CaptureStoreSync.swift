import Foundation
import CSQLite

// MARK: - CaptureStore Hybrid Capture, Sync Persistence & Convergence
// Extracted from HybridSync.swift so SQLite persistence stays cleanly separated from
// protocol/transport/scheduling logic. Mirrors spec/HybridSync.tla and spec/FilterSync.tla.

public extension CaptureStore {
    private static let syncEnabledKey = "sync_enabled"
    private static let autoSyncEnabledKey = "auto_sync_enabled"
    private static let syncTokenKey = "sync_change_token"
    private static let lastPushedDigestKey = "sync_last_pushed_digest"
    private static let localDeviceIDKey = "local_device_id"
    private static let sharedPrefColorThemeKey = "pref_color_theme"
    private static let sharedPrefGroupByAppKey = "pref_group_by_app"
    private static let sharedPrefUpdatedAtKey = "pref_updated_at"
    private static let syncResyncGenerationKey = "sync_v2_resync_gen"
    private static let currentSyncResyncGeneration = "2"
    internal static let localPrunedBeforeKey = "local_pruned_before"

    /// Ensures devices that upgraded across v1 -> v2 (or from earlier v0.2.2/build 158 builds affected
    /// by identity/workspace upsert rollbacks) perform one clean full CloudKit zone pull & push.
    internal func ensureV2SyncResyncIfNeeded() throws {
        let current = try syncStateValue(for: Self.syncResyncGenerationKey)
        guard current != Self.currentSyncResyncGeneration else { return }
        try transaction {
            try deleteSyncStateValue(for: Self.syncTokenKey)
            try deleteSyncStateValue(for: Self.lastPushedDigestKey)
            try setSyncStateValue(Self.currentSyncResyncGeneration, for: Self.syncResyncGenerationKey)
        }
    }

    /// Direct structured observation capture (used by iOS 27 Shortcuts AppIntent and tests).
    /// Applies transactional sliding-window deduplication so rapid retries across minute boundaries stay idempotent.
    @discardableResult
    func recordDirectObservation(
        sourceID: String,
        originDeviceID: String,
        appLabel: String,
        title: String,
        subtitle: String = "",
        body: String,
        capturedAt: Double,
        origin: NotificationOrigin = .iphone,
        channel: SyncCaptureChannel = .iosShortcuts,
        dedupWindowSeconds: Double = 60.0
    ) throws -> (observationID: Int64, syncUUID: String, inserted: Bool) {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(Observation.appLabelDirectionMarks)
        let cleanApp = appLabel.trimmingCharacters(in: trimSet)
        guard !cleanApp.isEmpty else {
            throw StoreError(description: "App label cannot be empty.")
        }
        guard capturedAt.isFinite else {
            throw StoreError(description: "Invalid capture timestamp.")
        }
        let cleanTitle = title.trimmingCharacters(in: trimSet)
        let cleanSubtitle = subtitle.trimmingCharacters(in: trimSet)
        let cleanBody = body.trimmingCharacters(in: trimSet)
        let logicalKey = SyncLogicalKey.make(
            appLabel: cleanApp,
            title: cleanTitle,
            subtitle: cleanSubtitle,
            body: cleanBody
        )

        return try transaction {
            if dedupWindowSeconds > 0 {
                let existing = try readRows("""
                    SELECT o.id, coalesce(l.sync_uuid, '')
                    FROM observations o
                    LEFT JOIN sync_observation_links l ON l.observation_id = o.id
                    WHERE o.source_id = ?
                      AND lower(o.app_label) = lower(?)
                      AND o.title = ?
                      AND o.subtitle = ?
                      AND o.body = ?
                      AND abs(o.captured_at - ?) <= ?
                    ORDER BY o.captured_at DESC, o.id DESC
                    LIMIT 1
                    """, strings: [sourceID, cleanApp, cleanTitle, cleanSubtitle, cleanBody],
                         numbers: [capturedAt, dedupWindowSeconds]) { row in
                    (sqlite3_column_int64(row, 0), columnString(row, 1))
                }
                if let match = existing.first {
                    let uuid = match.1.isEmpty ? try ensureSyncLinkInTransaction(
                        observationID: match.0,
                        channel: channel,
                        originDeviceID: originDeviceID,
                        logicalKey: logicalKey,
                        at: capturedAt
                    ) : match.1
                    return (match.0, uuid, false)
                }
            }

            let runID = "direct:\(sourceID)"
            try execute("""
                INSERT INTO capture_runs(id, started_at, heartbeat_at)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET heartbeat_at = max(heartbeat_at, excluded.heartbeat_at)
                """, strings: [runID], numbers: [capturedAt, capturedAt])

            let syncUUID = UUID().uuidString
            let sourceEventID = "\(logicalKey):\(Int64((capturedAt * 1000).rounded()))"
            try execute("""
                INSERT INTO observations
                (source_id, source_event_id, run_id, origin, app_label, title, subtitle,
                 body, accessibility_description, captured_at, parser_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, strings: [sourceID, sourceEventID, runID, origin.rawValue, cleanApp, cleanTitle,
                               cleanSubtitle, cleanBody, ""],
                     numbers: [capturedAt, 1])

            let observationID = sqlite3_last_insert_rowid(database)
            try execute("""
                INSERT INTO sync_observation_links
                (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at, hidden_version, hidden_updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?, 0, 0)
                """, strings: [String(observationID), syncUUID, channel.rawValue, originDeviceID, logicalKey],
                     numbers: [capturedAt])

            return (observationID, syncUUID, true)
        }
    }

    // MARK: - Opt-In Pairing, Revocation & Shared Preferences

    func localSyncDeviceID() throws -> String {
        if let existing = try syncStateValue(for: Self.localDeviceIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        try setSyncStateValue(generated, for: Self.localDeviceIDKey)
        return generated
    }

    func isSyncEnabled() throws -> Bool {
        (try syncStateValue(for: Self.syncEnabledKey)) == "1"
    }

    func setSyncEnabled(_ enabled: Bool) throws {
        try setSyncStateValue(enabled ? "1" : "0", for: Self.syncEnabledKey)
    }

    func isAutoSyncEnabled() throws -> Bool {
        guard let value = try syncStateValue(for: Self.autoSyncEnabledKey) else {
            return true
        }
        return value != "0"
    }

    func setAutoSyncEnabled(_ enabled: Bool) throws {
        try setSyncStateValue(enabled ? "1" : "0", for: Self.autoSyncEnabledKey)
    }

    func sharedPreferences() throws -> SyncedUserPreferences? {
        guard let rawTime = try syncStateValue(for: Self.sharedPrefUpdatedAtKey),
              let updatedAt = Double(rawTime), updatedAt > 0 else {
            return nil
        }
        let colorTheme = try syncStateValue(for: Self.sharedPrefColorThemeKey)
        let groupByAppRaw = try syncStateValue(for: Self.sharedPrefGroupByAppKey)
        let groupByApp: Bool? = groupByAppRaw.map { $0 == "1" }
        return SyncedUserPreferences(
            colorThemeRaw: colorTheme?.isEmpty == true ? nil : colorTheme,
            groupByApp: groupByApp,
            updatedAt: updatedAt
        )
    }

    func saveSharedPreferences(_ prefs: SyncedUserPreferences) throws {
        guard prefs.updatedAt.isFinite && prefs.updatedAt > 0 else { return }
        _ = try transaction {
            try applySharedPreferencesInTransaction(prefs)
        }
    }

    private func applySharedPreferencesInTransaction(_ incoming: SyncedUserPreferences) throws -> Bool {
        let localUpdatedAt = (try syncStateValue(for: Self.sharedPrefUpdatedAtKey)).flatMap(Double.init) ?? 0
        let localColor = try syncStateValue(for: Self.sharedPrefColorThemeKey)
        let localGroupRaw = try syncStateValue(for: Self.sharedPrefGroupByAppKey)

        let shouldApply: Bool
        if incoming.updatedAt > localUpdatedAt {
            shouldApply = true
        } else if incoming.updatedAt == localUpdatedAt {
            // Deterministic tie-break for commutativity (mirrors MergeSharedPref in FilterSync.tla).
            let incomingKey = "\(incoming.colorThemeRaw ?? "")|\(incoming.groupByApp == true ? "1" : "0")"
            let localKey = "\(localColor ?? "")|\(localGroupRaw ?? "0")"
            shouldApply = incomingKey > localKey
        } else {
            shouldApply = false
        }
        guard shouldApply else { return false }

        if let theme = incoming.colorThemeRaw {
            try setSyncStateValue(theme, for: Self.sharedPrefColorThemeKey)
        }
        if let groupByApp = incoming.groupByApp {
            try setSyncStateValue(groupByApp ? "1" : "0", for: Self.sharedPrefGroupByAppKey)
        }
        try setSyncStateValue(String(incoming.updatedAt), for: Self.sharedPrefUpdatedAtKey)
        return true
    }

    internal func localPrunedBeforeTimestamp() throws -> Double? {
        guard let raw = try syncStateValue(for: Self.localPrunedBeforeKey),
              let ts = Double(raw), ts.isFinite, ts > 0 else {
            return nil
        }
        return ts
    }

    internal func setLocalPrunedBeforeTimestamp(_ cutoff: Double) throws {
        guard cutoff.isFinite && cutoff > 0 else { return }
        let existing = (try? localPrunedBeforeTimestamp()) ?? 0
        try setSyncStateValue(String(max(existing, cutoff)), for: Self.localPrunedBeforeKey)
    }

    internal func ensureAndBumpWorkflowVersion(for observationID: Int64, at time: Double = Date().timeIntervalSince1970) throws {
        let deviceID = try localSyncDeviceID()
        _ = try ensureSyncLinkInTransaction(
            observationID: observationID,
            channel: .macosAX,
            originDeviceID: deviceID,
            logicalKey: nil,
            at: time
        )
        try execute("""
            UPDATE sync_observation_links
            SET workflow_version = workflow_version + 1, updated_at = max(updated_at, ?)
            WHERE observation_id = ?
            """, numbersFirst: [time], strings: [String(observationID)])
    }

    internal func ensureAndBumpHiddenVersion(for observationID: Int64, at time: Double = Date().timeIntervalSince1970) throws {
        let deviceID = try localSyncDeviceID()
        _ = try ensureSyncLinkInTransaction(
            observationID: observationID,
            channel: .macosAX,
            originDeviceID: deviceID,
            logicalKey: nil,
            at: time
        )
        try execute("""
            UPDATE sync_observation_links
            SET hidden_version = hidden_version + 1, hidden_updated_at = max(hidden_updated_at, ?)
            WHERE observation_id = ?
            """, numbersFirst: [time], strings: [String(observationID)])
    }

    internal func bumpExistingSyncWorkflowVersion(for observationID: Int64, at time: Double = Date().timeIntervalSince1970) throws {
        try ensureAndBumpWorkflowVersion(for: observationID, at: time)
    }

    /// Finds observations of the same logical alert captured on a **different** source/device
    /// within `windowSeconds` (so identical DMs on the same device are never merged).
    internal func crossDeviceTwinIDs(
        for observationID: Int64,
        windowSeconds: Double = 300.0
    ) throws -> [Int64] {
        let baseRows = try readRows("""
            SELECT o.source_id, coalesce(o.app_label, ''), o.title, o.subtitle, o.body,
                   o.captured_at, coalesce(l.logical_key, '')
            FROM observations o
            LEFT JOIN sync_observation_links l ON l.observation_id = o.id
            WHERE o.id = ?
            LIMIT 1
            """, strings: [String(observationID)]) { row in
            (
                sourceID: columnString(row, 0),
                app: columnString(row, 1),
                title: columnString(row, 2),
                subtitle: columnString(row, 3),
                body: columnString(row, 4),
                capturedAt: sqlite3_column_double(row, 5),
                logicalKey: columnString(row, 6)
            )
        }
        guard let base = baseRows.first else { return [] }
        let targetKey = base.logicalKey.isEmpty
            ? SyncLogicalKey.make(appLabel: base.app, title: base.title, subtitle: base.subtitle, body: base.body)
            : base.logicalKey

        let candidates = try readRows("""
            SELECT o.id, coalesce(o.app_label, ''), o.title, o.subtitle, o.body, coalesce(l.logical_key, '')
            FROM observations o
            LEFT JOIN sync_observation_links l ON l.observation_id = o.id
            WHERE o.id != ?
              AND o.source_id != ?
              AND abs(o.captured_at - ?) <= ?
            """, strings: [String(observationID), base.sourceID],
                 numbers: [base.capturedAt, windowSeconds]) { row -> (Int64, String) in
            let id = sqlite3_column_int64(row, 0)
            let storedKey = columnString(row, 5)
            let key = storedKey.isEmpty
                ? SyncLogicalKey.make(
                    appLabel: columnString(row, 1),
                    title: columnString(row, 2),
                    subtitle: columnString(row, 3),
                    body: columnString(row, 4)
                )
                : storedKey
            return (id, key)
        }
        return candidates.filter { $0.1 == targetKey }.map(\.0)
    }

    func registerOrUpdateDevice(
        deviceID: String,
        displayName: String,
        platform: SyncDevicePlatform,
        status: SyncDeviceStatus,
        at time: Double = Date().timeIntervalSince1970
    ) throws {
        let pairedAt: Double? = status == .paired ? time : nil
        let revokedAt: Double? = status == .revoked ? time : nil
        try transaction {
            let existing = try readRows(
                "SELECT paired_at, revoked_at, last_synced_at FROM sync_devices WHERE device_id = ?",
                strings: [deviceID]
            ) { row in
                (
                    sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : sqlite3_column_double(row, 0),
                    sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : sqlite3_column_double(row, 1),
                    sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_double(row, 2)
                )
            }.first

            if existing != nil {
                try execute("""
                    UPDATE sync_devices
                    SET display_name = ?, platform = ?, status = ?,
                        paired_at = coalesce(?, paired_at),
                        revoked_at = CASE WHEN ? = 'revoked' THEN coalesce(?, revoked_at) ELSE NULL END
                    WHERE device_id = ?
                    """, strings: [displayName, platform.rawValue, status.rawValue,
                                   pairedAt.map { String($0) }, status.rawValue,
                                   revokedAt.map { String($0) }, deviceID])
            } else {
                let stmt = try prepare("""
                    INSERT INTO sync_devices (device_id, display_name, platform, status, paired_at, revoked_at, last_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """, strings: [deviceID, displayName, platform.rawValue, status.rawValue,
                                   pairedAt.map { String($0) }, revokedAt.map { String($0) }])
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    func pairDevice(
        deviceID: String,
        displayName: String,
        platform: SyncDevicePlatform,
        at time: Double = Date().timeIntervalSince1970
    ) throws {
        try setSyncEnabled(true)
        try registerOrUpdateDevice(
            deviceID: deviceID,
            displayName: displayName,
            platform: platform,
            status: .paired,
            at: time
        )
    }

    /// Revokes a device from sync and clears stale local sync cursor/digest state if it is the local device,
    /// preserving all local user data intact.
    func revokeDevice(_ deviceID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try transaction {
            try execute("""
                UPDATE sync_devices SET status = 'revoked', revoked_at = ?
                WHERE device_id = ?
                """, numbersFirst: [time], strings: [deviceID])
            let local = try syncStateValue(for: Self.localDeviceIDKey)
            let remainingPaired = try scalar("SELECT count(*) FROM sync_devices WHERE status = 'paired'")
            if local == deviceID || remainingPaired == 0 {
                try setSyncStateValue("0", for: Self.syncEnabledKey)
                try deleteSyncStateValue(for: Self.syncTokenKey)
                try deleteSyncStateValue(for: Self.lastPushedDigestKey)
            }
        }
    }

    /// Clears sync change cursor and digest without deleting user data (useful on iCloud account switch/sign-out).
    func resetLocalSyncCursors() throws {
        try transaction {
            try deleteSyncStateValue(for: Self.syncTokenKey)
            try deleteSyncStateValue(for: Self.lastPushedDigestKey)
        }
    }

    func syncDevices() throws -> [SyncDeviceRecord] {
        try readRows("""
            SELECT device_id, display_name, platform, status, paired_at, revoked_at, last_synced_at
            FROM sync_devices
            ORDER BY coalesce(paired_at, 0) DESC, device_id
            """) { row in
            SyncDeviceRecord(
                deviceID: columnString(row, 0),
                displayName: columnString(row, 1),
                platform: SyncDevicePlatform(rawValue: columnString(row, 2)) ?? .unknown,
                status: SyncDeviceStatus(rawValue: columnString(row, 3)) ?? .localOnly,
                pairedAt: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : sqlite3_column_double(row, 4),
                revokedAt: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : sqlite3_column_double(row, 5),
                lastSyncedAt: sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : sqlite3_column_double(row, 6)
            )
        }
    }

    func canDeviceSync(_ deviceID: String) throws -> Bool {
        guard try isSyncEnabled() else { return false }
        let status = try readRows(
            "SELECT status FROM sync_devices WHERE device_id = ?",
            strings: [deviceID]
        ) { columnString($0, 0) }.first
        return status == SyncDeviceStatus.paired.rawValue
    }

    func markDeviceSynced(_ deviceID: String, at time: Double) throws {
        try execute("UPDATE sync_devices SET last_synced_at = ? WHERE device_id = ?",
                    numbersFirst: [time], strings: [deviceID])
    }

    func syncChangeToken() throws -> Data? {
        guard let encoded = try syncStateValue(for: Self.syncTokenKey), !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded)
    }

    func saveSyncChangeToken(_ token: Data) throws {
        try setSyncStateValue(token.base64EncodedString(), for: Self.syncTokenKey)
    }

    func lastPushedDigest() throws -> String? {
        try syncStateValue(for: Self.lastPushedDigestKey)
    }

    func saveLastPushedDigest(_ digest: String) throws {
        try setSyncStateValue(digest, for: Self.lastPushedDigestKey)
    }

    func macForwardingHealth(
        localDeviceID: String,
        enabledApps: Set<String> = [],
        now: Double = Date().timeIntervalSince1970,
        windowSeconds: Double = 24 * 3600
    ) throws -> MacForwardingHealthReport {
        let isPaired = try canDeviceSync(localDeviceID)
        guard isPaired else {
            return MacForwardingHealthAnalyzer.evaluate(
                isPaired: false,
                entries: [],
                provenanceByID: [:],
                enabledApps: enabledApps,
                now: now,
                windowSeconds: windowSeconds
            )
        }
        let entries = try inbox(InboxQuery(limit: 500))
        let provenance = try provenanceByObservationID()
        return MacForwardingHealthAnalyzer.evaluate(
            isPaired: true,
            entries: entries,
            provenanceByID: provenance,
            enabledApps: enabledApps,
            now: now,
            windowSeconds: windowSeconds
        )
    }

    // MARK: - Provenance & Tombstones

    func provenanceByObservationID() throws -> [Int64: ObservationProvenance] {
        let rows = try readRows("""
            SELECT o.id, coalesce(l.sync_uuid, ''), o.source_id, o.origin,
                   coalesce(l.capture_channel, 'macos_ax'),
                   coalesce(l.origin_device_id, o.source_id),
                   coalesce(l.logical_key, ''),
                   coalesce(l.workflow_version, 0),
                   coalesce(l.updated_at, o.captured_at),
                   coalesce(o.app_label, ''), o.title, o.subtitle, o.body
            FROM observations o
            LEFT JOIN sync_observation_links l ON l.observation_id = o.id
            """) { row -> ObservationProvenance in
            let id = sqlite3_column_int64(row, 0)
            let existingKey = columnString(row, 6)
            let logicalKey = existingKey.isEmpty ? SyncLogicalKey.make(
                appLabel: columnString(row, 9),
                title: columnString(row, 10),
                subtitle: columnString(row, 11),
                body: columnString(row, 12)
            ) : existingKey
            return ObservationProvenance(
                observationID: id,
                syncUUID: columnString(row, 1),
                sourceID: columnString(row, 2),
                origin: NotificationOrigin(rawValue: columnString(row, 3)) ?? .unknown,
                channel: SyncCaptureChannel(rawValue: columnString(row, 4)) ?? .macosAX,
                originDeviceID: columnString(row, 5),
                logicalKey: logicalKey,
                workflowVersion: Int(sqlite3_column_int64(row, 7)),
                updatedAt: sqlite3_column_double(row, 8)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.observationID, $0) })
    }

    func bumpWorkflowVersion(for observationID: Int64, originDeviceID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try transaction {
            _ = try ensureSyncLinkInTransaction(
                observationID: observationID,
                channel: .macosAX,
                originDeviceID: originDeviceID,
                logicalKey: nil,
                at: time
            )
            try execute("""
                UPDATE sync_observation_links
                SET workflow_version = workflow_version + 1, updated_at = max(updated_at, ?)
                WHERE observation_id = ?
                """, numbersFirst: [time], strings: [String(observationID)])
        }
    }

    func recordSyncTombstone(entityType: String, entityID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try execute("""
            INSERT INTO sync_tombstones (entity_type, entity_id, deleted_at)
            VALUES (?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET deleted_at = max(deleted_at, excluded.deleted_at)
            """, strings: [entityType, entityID], numbers: [time])
    }

    // MARK: - Filtered Sync Export & Deterministic Remote Apply

    /// Exports only non-hidden, non-tombstoned observations plus workflow, rules, hidden-state markers,
    /// CRM, workspaces, templates, and shared preferences.
    /// Enforces `UnpairedOrRevokedNeverSyncs` and `HiddenNeverLeaksToCloudOrIPhone`.
    func exportSyncBatch(deviceID: String, at time: Double = Date().timeIntervalSince1970) throws -> SyncBatch {
        guard try canDeviceSync(deviceID) else {
            throw StoreError(description: "Device \(deviceID) is not paired for sync.")
        }

        return try transaction {
            let app = Self.appCategory
            let hiddenClause = """
                (EXISTS (SELECT 1 FROM hidden_observations h WHERE h.observation_id = o.id)
                 OR EXISTS (SELECT 1 FROM inbox_filters f WHERE f.enabled = 1 AND f.app = \(app) AND f.field = 'title' AND f.value = o.title)
                 OR EXISTS (SELECT 1 FROM inbox_filters f WHERE f.enabled = 1 AND f.app = \(app) AND f.field = 'body' AND f.value = o.body)
                 OR EXISTS (SELECT 1 FROM inbox_filters f WHERE f.enabled = 1 AND f.app = \(app) AND f.field = 'app'))
                """

            let eligibleRows = try readRows("""
                SELECT o.id, o.source_id, o.source_event_id, o.origin,
                       coalesce(o.app_label, ''), o.title, o.subtitle, o.body, o.captured_at,
                       coalesce(l.sync_uuid, ''),
                       coalesce(l.capture_channel, 'macos_ax'),
                       coalesce(l.origin_device_id, ?),
                       coalesce(l.logical_key, ''),
                       coalesce(l.workflow_version, 0),
                       coalesce(l.updated_at, o.captured_at),
                       EXISTS (SELECT 1 FROM read_observations r WHERE r.observation_id = o.id),
                       EXISTS (SELECT 1 FROM flagged_observations fl WHERE fl.observation_id = o.id),
                       coalesce(w.saved, 0),
                       w.due_at,
                       coalesce(w.done, 0),
                       po.person_id,
                       ow.workspace_id
                FROM observations o
                LEFT JOIN sync_observation_links l ON l.observation_id = o.id
                LEFT JOIN observation_work w ON w.observation_id = o.id
                LEFT JOIN person_observations po ON po.observation_id = o.id
                LEFT JOIN observation_workspaces ow ON ow.observation_id = o.id
                WHERE NOT \(hiddenClause)
                ORDER BY o.captured_at DESC, o.id DESC
                """, strings: [deviceID]) { row in
                (
                    id: sqlite3_column_int64(row, 0),
                    sourceID: columnString(row, 1),
                    sourceEventID: columnString(row, 2),
                    origin: NotificationOrigin(rawValue: columnString(row, 3)) ?? .unknown,
                    appLabel: columnString(row, 4),
                    title: columnString(row, 5),
                    subtitle: columnString(row, 6),
                    body: columnString(row, 7),
                    capturedAt: sqlite3_column_double(row, 8),
                    syncUUID: columnString(row, 9),
                    channel: SyncCaptureChannel(rawValue: columnString(row, 10)) ?? .macosAX,
                    originDeviceID: columnString(row, 11),
                    logicalKey: columnString(row, 12),
                    workflowVersion: Int(sqlite3_column_int64(row, 13)),
                    updatedAt: sqlite3_column_double(row, 14),
                    isRead: sqlite3_column_int(row, 15) != 0,
                    isFlagged: sqlite3_column_int(row, 16) != 0,
                    saved: sqlite3_column_int(row, 17) != 0,
                    dueAt: sqlite3_column_type(row, 18) == SQLITE_NULL ? nil : sqlite3_column_double(row, 18),
                    done: sqlite3_column_int(row, 19) != 0,
                    personID: sqlite3_column_type(row, 20) == SQLITE_NULL ? nil : columnString(row, 20),
                    workspaceID: sqlite3_column_type(row, 21) == SQLITE_NULL ? nil : columnString(row, 21)
                )
            }

            let tombstones = try readRows(
                "SELECT entity_type, entity_id, deleted_at FROM sync_tombstones ORDER BY entity_type, entity_id"
            ) { row in
                SyncTombstoneRecord(
                    entityType: columnString(row, 0),
                    entityID: columnString(row, 1),
                    deletedAt: sqlite3_column_double(row, 2)
                )
            }
            let tombstoneMap: [String: [String: Double]] = tombstones.reduce(into: [:]) { acc, t in
                acc[t.entityType, default: [:]][t.entityID] = max(acc[t.entityType]?[t.entityID] ?? 0, t.deletedAt)
            }
            let tombstonedObs = Set(tombstoneMap["observation"]?.keys.map { $0 } ?? [])
            let tombstonedNotes = Set(tombstoneMap["personal_note"]?.keys.map { $0 } ?? [])
            let tombstonedPersonNotes = Set(tombstoneMap["person_note"]?.keys.map { $0 } ?? [])
            let tombstonedFolders = Set(tombstoneMap["note_folder"]?.keys.map { $0 } ?? [])
            let tombstonedPeople = Set(tombstoneMap["person"]?.keys.map { $0 } ?? [])
            let tombstonedIdentities = Set(tombstoneMap["identity"]?.keys.map { $0 } ?? [])
            let tombstonedMatchRules = Set(tombstoneMap["person_match_rule"]?.keys.map { $0 } ?? [])
            let tombstonedWorkspaces = Set(tombstoneMap["workspace"]?.keys.map { $0 } ?? [])

            var observations: [SyncedObservationRecord] = []
            var workflows: [SyncedWorkflowRecord] = []

            for row in eligibleRows {
                let logicalKey = row.logicalKey.isEmpty ? SyncLogicalKey.make(
                    appLabel: row.appLabel, title: row.title, subtitle: row.subtitle, body: row.body
                ) : row.logicalKey
                let syncUUID = row.syncUUID.isEmpty ? try ensureSyncLinkInTransaction(
                    observationID: row.id,
                    channel: row.channel,
                    originDeviceID: row.originDeviceID,
                    logicalKey: logicalKey,
                    at: row.capturedAt
                ) : row.syncUUID

                if tombstonedObs.contains(syncUUID) { continue }

                observations.append(SyncedObservationRecord(
                    syncUUID: syncUUID,
                    sourceID: row.sourceID,
                    sourceEventID: row.sourceEventID,
                    origin: row.origin,
                    captureChannel: row.channel,
                    originDeviceID: row.originDeviceID,
                    appLabel: row.appLabel,
                    title: row.title,
                    subtitle: row.subtitle,
                    body: row.body,
                    capturedAt: row.capturedAt,
                    logicalKey: logicalKey
                ))

                let hasWorkflowState = row.workflowVersion > 0 || row.isRead || row.isFlagged
                    || row.saved || row.dueAt != nil || row.personID != nil || row.workspaceID != nil
                if hasWorkflowState {
                    workflows.append(SyncedWorkflowRecord(
                        syncUUID: syncUUID,
                        isRead: row.isRead,
                        isFlagged: row.isFlagged,
                        saved: row.saved,
                        dueAt: row.dueAt,
                        done: row.done,
                        personID: row.personID,
                        workspaceID: row.workspaceID,
                        workflowVersion: max(1, row.workflowVersion),
                        updatedAt: row.updatedAt
                    ))
                }
            }

            // Export opaque individual hide/restore state markers (zero notification content).
            // Includes both post-v13 versioned hide/restore transitions AND pre-v13 hidden_observations
            // rows so dual-captured alerts hidden before v13 still propagate without leaking alert text.
            let preV13HiddenIDs = try readRows("""
                SELECT h.observation_id
                FROM hidden_observations h
                LEFT JOIN sync_observation_links l ON l.observation_id = h.observation_id
                WHERE l.observation_id IS NULL OR l.hidden_version = 0
                """) { sqlite3_column_int64($0, 0) }
            for obsID in preV13HiddenIDs {
                _ = try ensureSyncLinkInTransaction(
                    observationID: obsID,
                    channel: .macosAX,
                    originDeviceID: deviceID,
                    logicalKey: nil,
                    at: time
                )
                try execute("""
                    UPDATE sync_observation_links
                    SET hidden_version = max(hidden_version, 1),
                        hidden_updated_at = CASE WHEN hidden_updated_at > 0 THEN hidden_updated_at ELSE updated_at END
                    WHERE observation_id = ?
                    """, strings: [String(obsID)])
            }

            let hiddenAlerts = try readRows("""
                SELECT l.sync_uuid, l.logical_key,
                       EXISTS (SELECT 1 FROM hidden_observations h WHERE h.observation_id = l.observation_id),
                       l.hidden_version, l.hidden_updated_at
                FROM sync_observation_links l
                WHERE l.hidden_version > 0
                ORDER BY l.sync_uuid
                """) { row in
                SyncedHiddenAlertRecord(
                    syncUUID: columnString(row, 0),
                    logicalKey: columnString(row, 1),
                    isHidden: sqlite3_column_int(row, 2) != 0,
                    hiddenVersion: Int(sqlite3_column_int64(row, 3)),
                    updatedAt: sqlite3_column_double(row, 4)
                )
            }

            // Export hide rules (app, title, body) with enabled flag and LWW timestamps.
            let hideRules = try readRows("""
                SELECT app, field, value, enabled, updated_at
                FROM inbox_filters
                ORDER BY app, field, value
                """) { row -> SyncedHideRuleRecord? in
                guard let field = InboxRuleMatch.Field(rawValue: columnString(row, 1)) else { return nil }
                return SyncedHideRuleRecord(
                    app: columnString(row, 0),
                    field: field,
                    value: columnString(row, 2),
                    enabled: sqlite3_column_int(row, 3) != 0,
                    updatedAt: sqlite3_column_double(row, 4)
                )
            }.compactMap { $0 }

            let syncedPeople = try readRows("""
                SELECT id, display_name, updated_at FROM people ORDER BY id
                """) { row in
                SyncedPersonRecord(
                    id: columnString(row, 0),
                    displayName: columnString(row, 1),
                    updatedAt: sqlite3_column_double(row, 2)
                )
            }.filter { !tombstonedPeople.contains($0.id) }

            let syncedIdentities = try readRows("""
                SELECT id, person_id, platform, identifier, updated_at
                FROM identities WHERE person_id IS NOT NULL ORDER BY id
                """) { row in
                SyncedIdentityRecord(
                    id: columnString(row, 0),
                    personID: columnString(row, 1),
                    platform: columnString(row, 2),
                    identifier: columnString(row, 3),
                    updatedAt: sqlite3_column_double(row, 4)
                )
            }.filter { !tombstonedIdentities.contains($0.id) && !tombstonedPeople.contains($0.personID) }

            let syncedMatchRules = try readRows("""
                SELECT id, app, title, person_id, updated_at
                FROM person_match_rules ORDER BY id
                """) { row in
                SyncedPersonMatchRuleRecord(
                    id: columnString(row, 0),
                    app: columnString(row, 1),
                    title: columnString(row, 2),
                    personID: columnString(row, 3),
                    updatedAt: sqlite3_column_double(row, 4)
                )
            }.filter { !tombstonedMatchRules.contains($0.id) && !tombstonedPeople.contains($0.personID) }

            let syncedWorkspaces = try readRows("""
                SELECT id, name, updated_at FROM workspaces ORDER BY id
                """) { row in
                SyncedWorkspaceRecord(
                    id: columnString(row, 0),
                    name: columnString(row, 1),
                    updatedAt: sqlite3_column_double(row, 2)
                )
            }.filter { !tombstonedWorkspaces.contains($0.id) }

            let syncedPersonWorkspaces = try readRows("""
                SELECT person_id, workspace_id, updated_at
                FROM person_workspaces ORDER BY person_id, workspace_id
                """) { row in
                SyncedPersonWorkspaceRecord(
                    personID: columnString(row, 0),
                    workspaceID: columnString(row, 1),
                    updatedAt: sqlite3_column_double(row, 2)
                )
            }.filter { !tombstonedPeople.contains($0.personID) && !tombstonedWorkspaces.contains($0.workspaceID) }

            let syncedFolders = try readRows("""
                SELECT id, name, updated_at FROM note_folders ORDER BY id
                """) { row in
                SyncedNoteFolderRecord(
                    id: columnString(row, 0),
                    name: columnString(row, 1),
                    updatedAt: sqlite3_column_double(row, 2)
                )
            }.filter { !tombstonedFolders.contains($0.id) }

            let syncedPersonalNotes = try personalNotes()
                .filter { !tombstonedNotes.contains($0.id) }
                .map {
                    SyncedPersonalNoteRecord(
                        id: $0.id, folderID: $0.folderID, title: $0.title, body: $0.body,
                        createdAt: $0.createdAt, updatedAt: $0.updatedAt
                    )
                }

            var syncedPersonNotes: [SyncedPersonNoteRecord] = []
            for person in syncedPeople {
                for note in try personNotes(for: person.id) where !tombstonedPersonNotes.contains(note.id) {
                    syncedPersonNotes.append(SyncedPersonNoteRecord(
                        id: note.id, personID: person.id, title: note.title, body: note.body,
                        createdAt: note.createdAt, updatedAt: note.updatedAt
                    ))
                }
            }

            let syncedTemplates = try readRows("""
                SELECT template_id, version, definition
                FROM relationship_templates ORDER BY template_id, version
                """) { row in
                SyncedRelationshipTemplateRecord(
                    templateID: columnString(row, 0),
                    version: Int(sqlite3_column_int64(row, 1)),
                    definitionJSON: columnString(row, 2)
                )
            }

            let personTemplateRows = try readRows("""
                SELECT person_id, template_id, version, stage_id, updated_at
                FROM person_templates ORDER BY person_id
                """) { row in
                (
                    personID: columnString(row, 0),
                    templateID: columnString(row, 1),
                    version: Int(sqlite3_column_int64(row, 2)),
                    stageID: columnString(row, 3),
                    updatedAt: sqlite3_column_double(row, 4)
                )
            }.filter { !tombstonedPeople.contains($0.personID) }

            var syncedPersonTemplates: [SyncedPersonTemplateRecord] = []
            for pt in personTemplateRows {
                let completed = try readRows("""
                    SELECT milestone_id FROM person_template_milestones
                    WHERE person_id = ? AND completed = 1 ORDER BY milestone_id
                    """, strings: [pt.personID]) { columnString($0, 0) }
                syncedPersonTemplates.append(SyncedPersonTemplateRecord(
                    personID: pt.personID,
                    templateID: pt.templateID,
                    version: pt.version,
                    stageID: pt.stageID,
                    completedMilestones: completed,
                    updatedAt: pt.updatedAt
                ))
            }

            let preferences = try sharedPreferences()

            return SyncBatch(
                senderDeviceID: deviceID,
                exportedAt: time,
                observations: observations,
                workflows: workflows,
                people: syncedPeople,
                personNotes: syncedPersonNotes,
                noteFolders: syncedFolders,
                personalNotes: syncedPersonalNotes,
                tombstones: tombstones,
                hideRules: hideRules,
                hiddenAlerts: hiddenAlerts,
                identities: syncedIdentities,
                personMatchRules: syncedMatchRules,
                workspaces: syncedWorkspaces,
                personWorkspaces: syncedPersonWorkspaces,
                relationshipTemplates: syncedTemplates,
                personTemplates: syncedPersonTemplates,
                preferences: preferences
            )
        }
    }

    @discardableResult
    func applySyncBatch(
        _ batch: SyncBatch,
        localDeviceID: String,
        at time: Double = Date().timeIntervalSince1970
    ) throws -> SyncApplySummary {
        guard try canDeviceSync(localDeviceID) else {
            throw StoreError(description: "Device \(localDeviceID) is not paired for sync.")
        }

        return try transaction {
            // 1. Merge incoming tombstones monotonically (max deleted_at wins).
            var appliedTombstones = 0
            for t in batch.tombstones {
                try execute("""
                    INSERT INTO sync_tombstones (entity_type, entity_id, deleted_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(entity_type, entity_id) DO UPDATE SET deleted_at = max(deleted_at, excluded.deleted_at)
                    """, strings: [t.entityType, t.entityID], numbers: [t.deletedAt])
                appliedTombstones += 1
            }

            // Build merged tombstone table: [entityType: [entityID: deletedAt]]
            let allTombstones = try readRows("SELECT entity_type, entity_id, deleted_at FROM sync_tombstones") {
                (columnString($0, 0), columnString($0, 1), sqlite3_column_double($0, 2))
            }
            var tombstoneTime: [String: [String: Double]] = [:]
            for (entityType, entityID, deletedAt) in allTombstones {
                tombstoneTime[entityType, default: [:]][entityID] = max(tombstoneTime[entityType]?[entityID] ?? 0, deletedAt)
            }

            // Enforce tombstones against local tables where deletion dominates local timestamp.
            for (entityID, deletedAt) in tombstoneTime["personal_note"] ?? [:] {
                try execute("DELETE FROM personal_notes WHERE id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["person_note"] ?? [:] {
                try execute("DELETE FROM person_notes WHERE id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["note_folder"] ?? [:] {
                try execute("DELETE FROM note_folders WHERE id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["inbox_filter"] ?? [:] {
                let parts = entityID.split(separator: "\u{001F}", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 3 {
                    try execute("""
                        DELETE FROM inbox_filters
                        WHERE app = ? AND field = ? AND value = ? AND updated_at <= ?
                        """, strings: [parts[0], parts[1], parts[2]], numbers: [deletedAt])
                }
            }
            for (entityID, deletedAt) in tombstoneTime["identity"] ?? [:] {
                try execute("DELETE FROM identities WHERE id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["person_match_rule"] ?? [:] {
                try execute("DELETE FROM person_match_rules WHERE id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["person_workspace"] ?? [:] {
                let parts = entityID.split(separator: "\u{001F}", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    try execute("""
                        DELETE FROM person_workspaces
                        WHERE person_id = ? AND workspace_id = ? AND updated_at <= ?
                        """, strings: [parts[0], parts[1]], numbers: [deletedAt])
                }
            }
            for (entityID, deletedAt) in tombstoneTime["person_template"] ?? [:] {
                try execute("DELETE FROM person_templates WHERE person_id = ? AND updated_at <= ?",
                            strings: [entityID], numbers: [deletedAt])
            }
            for (entityID, deletedAt) in tombstoneTime["person"] ?? [:] {
                let rows = try readRows("SELECT updated_at FROM people WHERE id = ?", strings: [entityID]) {
                    sqlite3_column_double($0, 0)
                }
                if let localUpd = rows.first, localUpd <= deletedAt {
                    try execute("DELETE FROM person_observations WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM person_match_rules WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM identities WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM person_workspaces WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM person_notes WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM person_templates WHERE person_id = ?", strings: [entityID])
                    try execute("DELETE FROM people WHERE id = ?", strings: [entityID])
                }
            }

            let tombstonedObs = Set(tombstoneTime["observation"]?.keys.map { $0 } ?? [])

            // 2. Apply Hide Rules with exact FilterSync.tla merge semantics.
            var appliedHideRules = 0
            for rule in batch.hideRules {
                let key = rule.canonicalKey
                if let tombAt = tombstoneTime["inbox_filter"]?[key], rule.updatedAt <= tombAt {
                    // Deletion dominates stale rule.
                    continue
                }
                let existing = try readRows("""
                    SELECT enabled, updated_at FROM inbox_filters
                    WHERE app = ? AND field = ? AND value = ? LIMIT 1
                    """, strings: [rule.app, rule.field.rawValue, rule.value]) { row in
                    (enabled: sqlite3_column_int(row, 0) != 0, updatedAt: sqlite3_column_double(row, 1))
                }.first

                if let existing {
                    let resolvedEnabled: Bool
                    let resolvedUpdatedAt: Double
                    if rule.updatedAt > existing.updatedAt {
                        resolvedEnabled = rule.enabled
                        resolvedUpdatedAt = rule.updatedAt
                    } else if existing.updatedAt > rule.updatedAt {
                        resolvedEnabled = existing.enabled
                        resolvedUpdatedAt = existing.updatedAt
                    } else {
                        // Conservative tie-break (FilterSync.tla): enabled/hide beats disabled on equal timestamps.
                        resolvedEnabled = existing.enabled || rule.enabled
                        resolvedUpdatedAt = existing.updatedAt
                    }
                    if resolvedEnabled != existing.enabled || resolvedUpdatedAt > existing.updatedAt {
                        try execute("""
                            UPDATE inbox_filters SET enabled = ?, updated_at = ?
                            WHERE app = ? AND field = ? AND value = ?
                            """, numbersFirst: [resolvedEnabled ? 1 : 0, resolvedUpdatedAt],
                                 strings: [rule.app, rule.field.rawValue, rule.value])
                        appliedHideRules += 1
                    }
                } else {
                    try execute("""
                        INSERT INTO inbox_filters (app, field, value, enabled, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, strings: [rule.app, rule.field.rawValue, rule.value],
                             numbers: [rule.enabled ? 1 : 0, rule.updatedAt])
                    appliedHideRules += 1
                }
            }

            // 3. Apply People, Identities, Match Rules, Workspaces & Memberships.
            var appliedPeople = 0
            for person in batch.people {
                if let tombAt = tombstoneTime["person"]?[person.id], person.updatedAt <= tombAt { continue }
                try execute("""
                    INSERT INTO people (id, display_name, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = CASE WHEN excluded.updated_at >= people.updated_at THEN excluded.display_name ELSE people.display_name END,
                        updated_at = max(people.updated_at, excluded.updated_at)
                    """, strings: [person.id, person.displayName], numbers: [person.updatedAt])
                appliedPeople += 1
            }

            for identity in batch.identities {
                if let tombAt = tombstoneTime["identity"]?[identity.id], identity.updatedAt <= tombAt { continue }
                if let pTomb = tombstoneTime["person"]?[identity.personID], identity.updatedAt <= pTomb { continue }
                let personExists = try scalar("SELECT count(*) FROM people WHERE id = ?", strings: [identity.personID]) > 0
                guard personExists else { continue }

                // Check both PRIMARY KEY (id) and UNIQUE (platform, identifier) to avoid SQLite
                // secondary-unique ON CONFLICT mismatches rolling back the entire sync batch.
                let existingByID = try readRows(
                    "SELECT id, updated_at FROM identities WHERE id = ? LIMIT 1",
                    strings: [identity.id]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first

                let existingByKey = try readRows(
                    "SELECT id, updated_at FROM identities WHERE platform = ? AND identifier = ? LIMIT 1",
                    strings: [identity.platform, identity.identifier]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first

                if let match = existingByID {
                    if identity.updatedAt >= match.updatedAt {
                        // Avoid colliding with a distinct row that already owns (platform, identifier).
                        if existingByKey == nil || existingByKey?.id == match.id {
                            try execute("""
                                UPDATE identities
                                SET updated_at = max(updated_at, ?), person_id = ?, platform = ?, identifier = ?
                                WHERE id = ?
                                """, numbersFirst: [identity.updatedAt],
                                     strings: [identity.personID, identity.platform, identity.identifier, match.id])
                        }
                    }
                } else if let match = existingByKey {
                    if identity.updatedAt >= match.updatedAt {
                        try execute("""
                            UPDATE identities
                            SET updated_at = max(updated_at, ?), person_id = ?
                            WHERE id = ?
                            """, numbersFirst: [identity.updatedAt], strings: [identity.personID, match.id])
                    }
                } else {
                    try execute("""
                        INSERT INTO identities (id, person_id, platform, identifier, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, strings: [identity.id, identity.personID, identity.platform, identity.identifier],
                             numbers: [identity.updatedAt])
                }
            }

            for rule in batch.personMatchRules {
                if let tombAt = tombstoneTime["person_match_rule"]?[rule.id], rule.updatedAt <= tombAt { continue }
                let personExists = try scalar("SELECT count(*) FROM people WHERE id = ?", strings: [rule.personID]) > 0
                guard personExists else { continue }

                let existingByID = try readRows(
                    "SELECT id, updated_at FROM person_match_rules WHERE id = ? LIMIT 1",
                    strings: [rule.id]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first

                let existingByKey = try readRows(
                    "SELECT id, updated_at FROM person_match_rules WHERE app = ? AND title = ? LIMIT 1",
                    strings: [rule.app, rule.title]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first

                if let match = existingByID {
                    if rule.updatedAt >= match.updatedAt {
                        if existingByKey == nil || existingByKey?.id == match.id {
                            try execute("""
                                UPDATE person_match_rules
                                SET updated_at = max(updated_at, ?), app = ?, title = ?, person_id = ?
                                WHERE id = ?
                                """, numbersFirst: [rule.updatedAt],
                                     strings: [rule.app, rule.title, rule.personID, match.id])
                        }
                    }
                } else if let match = existingByKey {
                    if rule.updatedAt >= match.updatedAt {
                        try execute("""
                            UPDATE person_match_rules
                            SET updated_at = max(updated_at, ?), person_id = ?
                            WHERE id = ?
                            """, numbersFirst: [rule.updatedAt], strings: [rule.personID, match.id])
                    }
                } else {
                    try execute("""
                        INSERT INTO person_match_rules (id, app, title, person_id, after_observation_id, updated_at)
                        VALUES (?, ?, ?, ?, 0, ?)
                        """, strings: [rule.id, rule.app, rule.title, rule.personID], numbers: [rule.updatedAt])
                }
            }

            var appliedWorkspaces = 0
            for ws in batch.workspaces {
                if let tombAt = tombstoneTime["workspace"]?[ws.id], ws.updatedAt <= tombAt { continue }
                let existingByID = try readRows(
                    "SELECT id, updated_at FROM workspaces WHERE id = ? LIMIT 1",
                    strings: [ws.id]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first
                let existingByName = try readRows(
                    "SELECT id FROM workspaces WHERE name = ? COLLATE NOCASE LIMIT 1",
                    strings: [ws.name]
                ) { columnString($0, 0) }.first

                if let match = existingByID {
                    if ws.updatedAt >= match.updatedAt && (existingByName == nil || existingByName == match.id) {
                        try execute("""
                            UPDATE workspaces SET updated_at = max(updated_at, ?), name = ? WHERE id = ?
                            """, numbersFirst: [ws.updatedAt], strings: [ws.name, match.id])
                        appliedWorkspaces += 1
                    }
                } else if existingByName == nil {
                    try execute("""
                        INSERT INTO workspaces (id, name, updated_at) VALUES (?, ?, ?)
                        """, strings: [ws.id, ws.name], numbers: [ws.updatedAt])
                    appliedWorkspaces += 1
                }
            }

            for pw in batch.personWorkspaces {
                let key = "\(pw.personID)\u{001F}\(pw.workspaceID)"
                if let tombAt = tombstoneTime["person_workspace"]?[key], pw.updatedAt <= tombAt { continue }
                let ok = try scalar("""
                    SELECT (SELECT count(*) FROM people WHERE id = ?) * (SELECT count(*) FROM workspaces WHERE id = ?)
                    """, strings: [pw.personID, pw.workspaceID]) > 0
                guard ok else { continue }
                try execute("""
                    INSERT INTO person_workspaces (person_id, workspace_id, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(person_id, workspace_id) DO UPDATE SET
                        updated_at = max(person_workspaces.updated_at, excluded.updated_at)
                    """, strings: [pw.personID, pw.workspaceID], numbers: [pw.updatedAt])
            }

            // 4. Apply Note Folders, Personal Notes, People Notes & Relationship Templates.
            for folder in batch.noteFolders {
                if let tombAt = tombstoneTime["note_folder"]?[folder.id], folder.updatedAt <= tombAt { continue }
                let existingByID = try readRows(
                    "SELECT id, updated_at FROM note_folders WHERE id = ? LIMIT 1",
                    strings: [folder.id]
                ) { (id: columnString($0, 0), updatedAt: sqlite3_column_double($0, 1)) }.first
                let existingByName = try readRows(
                    "SELECT id FROM note_folders WHERE name = ? COLLATE NOCASE LIMIT 1",
                    strings: [folder.name]
                ) { columnString($0, 0) }.first

                if let match = existingByID {
                    if folder.updatedAt >= match.updatedAt && (existingByName == nil || existingByName == match.id) {
                        try execute("""
                            UPDATE note_folders SET updated_at = max(updated_at, ?), name = ? WHERE id = ?
                            """, numbersFirst: [folder.updatedAt], strings: [folder.name, match.id])
                    }
                } else if existingByName == nil {
                    try execute("""
                        INSERT INTO note_folders (id, name, updated_at) VALUES (?, ?, ?)
                        """, strings: [folder.id, folder.name], numbers: [folder.updatedAt])
                }
            }

            var appliedNotes = 0
            for note in batch.personalNotes {
                if let tombAt = tombstoneTime["personal_note"]?[note.id], note.updatedAt <= tombAt { continue }
                let resolvedFolderID: String?
                if let folderID = note.folderID,
                   try scalar("SELECT count(*) FROM note_folders WHERE id = ?", strings: [folderID]) > 0 {
                    resolvedFolderID = folderID
                } else {
                    resolvedFolderID = nil
                }
                try execute("""
                    INSERT INTO personal_notes (id, folder_id, title, body, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        folder_id = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.folder_id ELSE personal_notes.folder_id END,
                        title = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.title ELSE personal_notes.title END,
                        body = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.body ELSE personal_notes.body END,
                        updated_at = max(personal_notes.updated_at, excluded.updated_at)
                    """, strings: [note.id, resolvedFolderID, note.title, note.body],
                         numbers: [note.createdAt, note.updatedAt])
                appliedNotes += 1
            }

            for note in batch.personNotes {
                if let tombAt = tombstoneTime["person_note"]?[note.id], note.updatedAt <= tombAt { continue }
                let personExists = try scalar("SELECT count(*) FROM people WHERE id = ?", strings: [note.personID]) > 0
                guard personExists else { continue }
                try execute("""
                    INSERT INTO person_notes (id, person_id, title, body, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = CASE WHEN excluded.updated_at >= person_notes.updated_at THEN excluded.title ELSE person_notes.title END,
                        body = CASE WHEN excluded.updated_at >= person_notes.updated_at THEN excluded.body ELSE person_notes.body END,
                        updated_at = max(person_notes.updated_at, excluded.updated_at)
                    """, strings: [note.id, note.personID, note.title, note.body],
                         numbers: [note.createdAt, note.updatedAt])
                appliedNotes += 1
            }

            for tpl in batch.relationshipTemplates {
                try execute("""
                    INSERT INTO relationship_templates (template_id, version, definition)
                    VALUES (?, ?, ?)
                    ON CONFLICT(template_id, version) DO NOTHING
                    """, strings: [tpl.templateID, String(tpl.version), tpl.definitionJSON])
            }

            for pt in batch.personTemplates {
                if let tombAt = tombstoneTime["person_template"]?[pt.personID], pt.updatedAt <= tombAt { continue }
                let existsOK = try scalar("""
                    SELECT (SELECT count(*) FROM people WHERE id = ?)
                         * (SELECT count(*) FROM relationship_templates WHERE template_id = ? AND version = ?)
                    """, strings: [pt.personID, pt.templateID, String(pt.version)]) > 0
                guard existsOK else { continue }
                let existingUpdatedAt = try readRows(
                    "SELECT updated_at FROM person_templates WHERE person_id = ? LIMIT 1",
                    strings: [pt.personID]
                ) { sqlite3_column_double($0, 0) }.first
                if let existingUpdatedAt, pt.updatedAt < existingUpdatedAt { continue }

                try execute("""
                    INSERT INTO person_templates (person_id, template_id, version, stage_id, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(person_id) DO UPDATE SET
                        template_id = excluded.template_id,
                        version = excluded.version,
                        stage_id = excluded.stage_id,
                        updated_at = max(person_templates.updated_at, excluded.updated_at)
                    """, strings: [pt.personID, pt.templateID, String(pt.version), pt.stageID],
                         numbers: [pt.updatedAt])

                let defRows = try readRows(
                    "SELECT definition FROM relationship_templates WHERE template_id = ? AND version = ?",
                    strings: [pt.templateID, String(pt.version)]
                ) { columnString($0, 0) }
                if let defJSON = defRows.first,
                   let definition = try? RelationshipTemplate.decode(Data(defJSON.utf8)) {
                    let completedSet = Set(pt.completedMilestones)
                    for milestone in definition.milestones {
                        try execute("""
                            INSERT INTO person_template_milestones (person_id, milestone_id, completed)
                            VALUES (?, ?, ?)
                            ON CONFLICT(person_id, milestone_id) DO UPDATE SET completed = excluded.completed
                            """, strings: [pt.personID, milestone.id],
                                 numbers: [completedSet.contains(milestone.id) ? 1 : 0])
                    }
                }
            }

            // 5. Apply Observations (respecting tombstones and device-local storage cleanup watermark).
            let localPrunedBefore = try localPrunedBeforeTimestamp()
            var insertedObservations = 0
            for obs in batch.observations where !tombstonedObs.contains(obs.syncUUID) {
                if let prunedBefore = localPrunedBefore, obs.capturedAt < prunedBefore {
                    continue
                }
                let existingID = try readRows(
                    "SELECT observation_id FROM sync_observation_links WHERE sync_uuid = ? LIMIT 1",
                    strings: [obs.syncUUID]
                ) { sqlite3_column_int64($0, 0) }.first
                if existingID != nil { continue }

                let runID = "sync:\(obs.originDeviceID)"
                try execute("""
                    INSERT INTO capture_runs(id, started_at, heartbeat_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET heartbeat_at = max(heartbeat_at, excluded.heartbeat_at)
                    """, strings: [runID], numbers: [obs.capturedAt, obs.capturedAt])

                try execute("""
                    INSERT INTO observations
                    (source_id, source_event_id, run_id, origin, app_label, title, subtitle,
                     body, accessibility_description, captured_at, parser_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_id, source_event_id, origin, title, subtitle, body,
                                accessibility_description, parser_version) DO NOTHING
                    """, strings: [obs.sourceID, obs.sourceEventID, runID, obs.origin.rawValue,
                                   obs.appLabel, obs.title, obs.subtitle, obs.body, ""],
                         numbers: [obs.capturedAt, 1])

                let obsID: Int64
                if sqlite3_changes(database) > 0 {
                    obsID = sqlite3_last_insert_rowid(database)
                    insertedObservations += 1
                } else {
                    let matchedRows = try readRows("""
                        SELECT id FROM observations
                        WHERE source_id = ? AND source_event_id = ? AND title = ? AND body = ?
                        LIMIT 1
                        """, strings: [obs.sourceID, obs.sourceEventID, obs.title, obs.body]) {
                        sqlite3_column_int64($0, 0)
                    }
                    guard let matched = matchedRows.first else { continue }
                    obsID = matched
                }

                try execute("""
                    INSERT OR IGNORE INTO sync_observation_links
                    (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at, hidden_version, hidden_updated_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?, 0, 0)
                    """, strings: [String(obsID), obs.syncUUID, obs.captureChannel.rawValue,
                                   obs.originDeviceID, obs.logicalKey],
                         numbers: [time])

                // If a local cross-device twin was already hidden locally, keep the newly synced twin hidden too.
                let localTwins = (try? crossDeviceTwinIDs(for: obsID)) ?? []
                if !localTwins.isEmpty {
                    let anyHidden = localTwins.contains { twinID in
                        let rows = (try? readRows(
                            "SELECT 1 FROM hidden_observations WHERE observation_id = ? LIMIT 1",
                            strings: [String(twinID)]
                        ) { _ in 1 }) ?? []
                        return !rows.isEmpty
                    }
                    if anyHidden {
                        try execute("INSERT OR IGNORE INTO hidden_observations VALUES (?)", strings: [String(obsID)])
                    }
                }
            }

            // 6. Apply Workflow States (read/dimmed, flagged, saved, follow-up, person link, alert workspace).
            var appliedWorkflows = 0
            for wf in batch.workflows where !tombstonedObs.contains(wf.syncUUID) {
                let linkRows = try readRows("""
                    SELECT observation_id
                    FROM sync_observation_links WHERE sync_uuid = ? LIMIT 1
                    """, strings: [wf.syncUUID]) { sqlite3_column_int64($0, 0) }
                guard let primaryID = linkRows.first else { continue }

                if try applyWorkflowStateInTransaction(wf, toObservationID: primaryID, localDeviceID: localDeviceID, at: time) {
                    appliedWorkflows += 1
                }

                let twins = (try? crossDeviceTwinIDs(for: primaryID)) ?? []
                for twinID in twins {
                    _ = try applyWorkflowStateInTransaction(wf, toObservationID: twinID, localDeviceID: localDeviceID, at: time)
                }
            }

            // 7. Apply Privacy-Preserving Individual Hidden / Restore Markers (only for alerts already on this device).
            var appliedHiddenAlerts = 0
            for marker in batch.hiddenAlerts {
                let targetIDs = try readRows("""
                    SELECT observation_id FROM sync_observation_links
                    WHERE sync_uuid = ? OR logical_key = ?
                    """, strings: [marker.syncUUID, marker.logicalKey]) { sqlite3_column_int64($0, 0) }
                var allTargets = Set(targetIDs)
                for id in targetIDs {
                    for twinID in (try? crossDeviceTwinIDs(for: id)) ?? [] {
                        allTargets.insert(twinID)
                    }
                }
                for targetID in allTargets {
                    if try applyHiddenMarkerInTransaction(marker, toObservationID: targetID, localDeviceID: localDeviceID, at: time) {
                        appliedHiddenAlerts += 1
                    }
                }
            }

            // 8. Apply Shared User Preferences (LWW; device-local settings remain untouched).
            var appliedPreferences = false
            if let prefs = batch.preferences {
                appliedPreferences = try applySharedPreferencesInTransaction(prefs)
            }

            return SyncApplySummary(
                insertedObservations: insertedObservations,
                appliedWorkflows: appliedWorkflows,
                appliedPeople: appliedPeople,
                appliedNotes: appliedNotes,
                appliedTombstones: appliedTombstones,
                appliedHideRules: appliedHideRules,
                appliedHiddenAlerts: appliedHiddenAlerts,
                appliedWorkspaces: appliedWorkspaces,
                appliedPreferences: appliedPreferences
            )
        }
    }

    // MARK: - Internal Sync Helpers

    private func applyHiddenMarkerInTransaction(
        _ marker: SyncedHiddenAlertRecord,
        toObservationID targetID: Int64,
        localDeviceID: String,
        at time: Double
    ) throws -> Bool {
        _ = try ensureSyncLinkInTransaction(
            observationID: targetID,
            channel: .macosAX,
            originDeviceID: localDeviceID,
            logicalKey: nil,
            at: time
        )
        let row = try readRows("""
            SELECT hidden_version, hidden_updated_at,
                   EXISTS (SELECT 1 FROM hidden_observations h WHERE h.observation_id = sync_observation_links.observation_id)
            FROM sync_observation_links WHERE observation_id = ? LIMIT 1
            """, strings: [String(targetID)]) { r in
            (
                version: Int(sqlite3_column_int64(r, 0)),
                updatedAt: sqlite3_column_double(r, 1),
                localHidden: sqlite3_column_int(r, 2) != 0
            )
        }.first
        guard let link = row else { return false }

        let shouldApply: Bool
        if marker.hiddenVersion > link.version {
            shouldApply = true
        } else if marker.hiddenVersion == link.version {
            if marker.updatedAt > link.updatedAt {
                shouldApply = true
            } else if marker.updatedAt == link.updatedAt {
                // Conservative tie-break: hidden wins over visible on equal version & timestamp.
                shouldApply = marker.isHidden && !link.localHidden
            } else {
                shouldApply = false
            }
        } else {
            shouldApply = false
        }
        guard shouldApply else { return false }

        if marker.isHidden {
            try execute("INSERT OR IGNORE INTO hidden_observations (observation_id) VALUES (?)",
                        strings: [String(targetID)])
        } else {
            try execute("DELETE FROM hidden_observations WHERE observation_id = ?",
                        strings: [String(targetID)])
        }
        try execute("""
            UPDATE sync_observation_links
            SET hidden_version = ?, hidden_updated_at = max(hidden_updated_at, ?)
            WHERE observation_id = ?
            """, numbersFirst: [Double(marker.hiddenVersion), marker.updatedAt],
                 strings: [String(targetID)])
        return true
    }

    private func applyWorkflowStateInTransaction(
        _ wf: SyncedWorkflowRecord,
        toObservationID targetID: Int64,
        localDeviceID: String,
        at time: Double
    ) throws -> Bool {
        _ = try ensureSyncLinkInTransaction(
            observationID: targetID,
            channel: .macosAX,
            originDeviceID: localDeviceID,
            logicalKey: nil,
            at: time
        )
        let linkRows = try readRows("""
            SELECT workflow_version, updated_at
            FROM sync_observation_links WHERE observation_id = ? LIMIT 1
            """, strings: [String(targetID)]) { row in
            (
                version: Int(sqlite3_column_int64(row, 0)),
                updatedAt: sqlite3_column_double(row, 1)
            )
        }
        guard let link = linkRows.first else { return false }

        let isNewer = wf.workflowVersion > link.version
            || (wf.workflowVersion == link.version && wf.updatedAt > link.updatedAt)
        guard isNewer else { return false }

        if wf.isRead {
            try execute("INSERT OR IGNORE INTO read_observations (observation_id) VALUES (?)",
                        strings: [String(targetID)])
        } else {
            try execute("DELETE FROM read_observations WHERE observation_id = ?",
                        strings: [String(targetID)])
        }

        if wf.isFlagged {
            try execute("INSERT OR IGNORE INTO flagged_observations (observation_id) VALUES (?)",
                        strings: [String(targetID)])
        } else {
            try execute("DELETE FROM flagged_observations WHERE observation_id = ?",
                        strings: [String(targetID)])
        }

        let savedNum: Double = wf.saved ? 1 : 0
        let doneNum: Double = (wf.dueAt != nil && wf.done) ? 1 : 0
        if let dueAt = wf.dueAt {
            try execute("""
                INSERT INTO observation_work (observation_id, saved, due_at, done)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(observation_id) DO UPDATE SET
                    saved = excluded.saved, due_at = excluded.due_at, done = excluded.done
                """, strings: [String(targetID)], numbers: [savedNum, dueAt, doneNum])
        } else {
            try execute("""
                INSERT INTO observation_work (observation_id, saved, due_at, done)
                VALUES (?, ?, NULL, 0)
                ON CONFLICT(observation_id) DO UPDATE SET
                    saved = excluded.saved, due_at = NULL, done = 0
                """, strings: [String(targetID)], numbers: [savedNum])
        }

        if let personID = wf.personID,
           try scalar("SELECT count(*) FROM people WHERE id = ?", strings: [personID]) > 0 {
            try execute("""
                INSERT INTO person_observations (observation_id, person_id, method)
                VALUES (?, ?, 'manual')
                ON CONFLICT(observation_id) DO UPDATE SET person_id = excluded.person_id
                """, strings: [String(targetID), personID])
        } else {
            try execute("DELETE FROM person_observations WHERE observation_id = ?",
                        strings: [String(targetID)])
        }

        if let workspaceID = wf.workspaceID,
           try scalar("SELECT count(*) FROM workspaces WHERE id = ?", strings: [workspaceID]) > 0 {
            try execute("""
                INSERT INTO observation_workspaces (observation_id, workspace_id)
                VALUES (?, ?)
                ON CONFLICT(observation_id) DO UPDATE SET workspace_id = excluded.workspace_id
                """, strings: [String(targetID), workspaceID])
        } else {
            try execute("DELETE FROM observation_workspaces WHERE observation_id = ?",
                        strings: [String(targetID)])
        }

        try execute("""
            UPDATE sync_observation_links
            SET workflow_version = ?, updated_at = max(updated_at, ?)
            WHERE observation_id = ?
            """, numbersFirst: [Double(wf.workflowVersion), wf.updatedAt],
                 strings: [String(targetID)])
        return true
    }

    internal func ensureSyncLinkInTransaction(
        observationID: Int64,
        channel: SyncCaptureChannel,
        originDeviceID: String,
        logicalKey: String?,
        at time: Double
    ) throws -> String {
        let existingRows = try readRows(
            "SELECT sync_uuid FROM sync_observation_links WHERE observation_id = ? LIMIT 1",
            strings: [String(observationID)]
        ) { columnString($0, 0) }
        if let existing = existingRows.first {
            return existing
        }

        let resolvedKey: String
        if let logicalKey, !logicalKey.isEmpty {
            resolvedKey = logicalKey
        } else {
            let fields = try readRows(
                "SELECT coalesce(app_label, ''), title, subtitle, body FROM observations WHERE id = ?",
                strings: [String(observationID)]
            ) { (columnString($0, 0), columnString($0, 1), columnString($0, 2), columnString($0, 3)) }.first
            resolvedKey = SyncLogicalKey.make(
                appLabel: fields?.0 ?? "",
                title: fields?.1 ?? "",
                subtitle: fields?.2 ?? "",
                body: fields?.3 ?? ""
            )
        }

        let syncUUID = UUID().uuidString
        try execute("""
            INSERT INTO sync_observation_links
            (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at, hidden_version, hidden_updated_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, 0, 0)
            """, strings: [String(observationID), syncUUID, channel.rawValue, originDeviceID, resolvedKey],
                 numbers: [time])
        return syncUUID
    }

    internal func syncStateValue(for key: String) throws -> String? {
        try readRows("SELECT value FROM sync_state WHERE key = ? LIMIT 1", strings: [key]) {
            columnString($0, 0)
        }.first
    }

    internal func setSyncStateValue(_ value: String, for key: String) throws {
        try execute("""
            INSERT INTO sync_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, strings: [key, value])
    }

    internal func deleteSyncStateValue(for key: String) throws {
        try execute("DELETE FROM sync_state WHERE key = ?", strings: [key])
    }
}
