import Foundation
import CSQLite

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

public struct CaptureBatchResult {
    public let observed: Int
    public let inserted: Int
    public var duplicates: Int { observed - inserted }
}

public struct StoredObservation: Identifiable {
    public let id: Int64
    public let appLabel: String
    public let title: String
    public let body: String
    public let capturedAt: Double
}

public struct AppCaptureSummary {
    public let appLabel: String
    public let count: Int
    public let lastCapturedAt: Double
}

/// Use one collector owner per database. SQLite transactions protect all durable writes.
public final class CaptureStore {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Open failed"
            sqlite3_close(database)
            database = nil
            throw StoreError(description: message)
        }
        do {
            sqlite3_busy_timeout(database, 3000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            let version = try scalar("PRAGMA user_version")
            guard (0...2).contains(version) else {
                throw StoreError(description: "Unsupported database version \(version)")
            }
            if version < 2 {
                try transaction {
                    // Recheck under the write lock if another process opened concurrently.
                    let current = try scalar("PRAGMA user_version")
                    if current == 0 {
                        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                            throw StoreError(description: "Expected a new empty Notifdex database")
                        }
                        try execute(Self.schema(named: "schema"))
                    }
                    if current == 0 || current == 1 {
                        try execute(Self.schema(named: "rolodex"))
                        try execute("PRAGMA user_version = 2")
                    } else if current != 2 {
                        throw StoreError(description: "Unsupported database version \(current)")
                    }
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    static func schema(named name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "sql")
                ?? Bundle.module.url(forResource: name, withExtension: "sql") else {
            throw StoreError(description: "Missing database schema: \(name)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    deinit { sqlite3_close(database) }

    public func startRun(at time: Double) throws -> String {
        let runID = UUID().uuidString
        try transaction {
            let prior = try scalar("SELECT count(*) FROM capture_runs")
            // The exact crash time is unknown. Use the last durable heartbeat as a bound.
            try execute("""
                INSERT INTO coverage_gaps(run_id, reason, started_at, ended_at)
                SELECT id, 'unclean_exit', heartbeat_at, max(heartbeat_at, ?)
                FROM capture_runs WHERE ended_at IS NULL
                """, numbers: [time])
            let unclean = sqlite3_changes(database) > 0
            if prior > 0 && !unclean {
                try execute("""
                    INSERT INTO coverage_gaps(run_id, reason, started_at, ended_at)
                    SELECT id, 'collector_stopped', ended_at, max(ended_at, ?)
                    FROM capture_runs ORDER BY started_at DESC LIMIT 1
                    """, numbers: [time])
            }
            // End the prior process's active intervals. The new startup-scan
            // interval carries uncertainty forward until a scan succeeds.
            try execute("UPDATE coverage_gaps SET ended_at = max(started_at, ?) WHERE ended_at IS NULL",
                        numbers: [time])
            try execute("UPDATE capture_runs SET ended_at = max(started_at, ?) WHERE ended_at IS NULL", numbers: [time])
            try execute("INSERT INTO capture_runs(id, started_at, heartbeat_at) VALUES (?, ?, ?)",
                        strings: [runID], numbers: [time, time])
            try openGap(runID: runID, reason: "startup_scan", at: time)
        }
        return runID
    }

    @discardableResult
    public func record(_ value: Observation, runID: String) throws -> Bool {
        try recordBatch([value], runID: runID, at: value.capturedAt).inserted == 1
    }

    /// Atomically persist a snapshot. Counters describe this committed attempt.
    public func recordBatch(_ values: [Observation], runID: String, at time: Double) throws -> CaptureBatchResult {
        var inserted = 0
        try transaction {
            try heartbeat(runID: runID, at: time)
            for value in values {
                try execute("""
                INSERT INTO observations
                (source_id, source_event_id, run_id, origin, app_label, title, subtitle,
                 body, accessibility_description, captured_at, parser_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, source_event_id, origin, title, subtitle, body,
                            accessibility_description, parser_version) DO NOTHING
                """, strings: [value.sourceID, value.sourceEventID, runID, value.origin.rawValue,
                               value.appLabel, value.title, value.subtitle, value.body,
                               value.accessibilityDescription],
                        numbers: [value.capturedAt, Double(value.parserVersion)])
                inserted += Int(sqlite3_changes(database))
            }
        }
        return CaptureBatchResult(observed: values.count, inserted: inserted)
    }

    public func heartbeat(runID: String, at time: Double) throws {
        try execute("UPDATE capture_runs SET heartbeat_at = max(heartbeat_at, ?) WHERE id = ? AND ended_at IS NULL",
                    numbersFirst: [time], strings: [runID])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "Unknown or ended capture run") }
    }

    public func openGap(runID: String, reason: String, at time: Double) throws {
        try execute("""
            INSERT INTO coverage_gaps(run_id, reason, started_at) VALUES (?, ?, ?)
            ON CONFLICT(run_id, reason) WHERE ended_at IS NULL DO NOTHING
            """, strings: [runID, reason], numbers: [time])
    }

    public func recover(runID: String, at time: Double) throws {
        try execute("""
            UPDATE coverage_gaps SET ended_at = max(started_at, ?), recovery_scanned_at = ?
            WHERE run_id = ? AND ended_at IS NULL
            """, numbersFirst: [time, time], strings: [runID])
    }

    public func finishRun(runID: String, at time: Double) throws {
        try execute("UPDATE capture_runs SET ended_at = max(started_at, ?) WHERE id = ?",
                    numbersFirst: [time], strings: [runID])
    }

    public func observationCount() throws -> Int { try scalar("SELECT count(*) FROM observations") }
    public func openGapCount() throws -> Int { try scalar("SELECT count(*) FROM coverage_gaps WHERE ended_at IS NULL") }
    public func gapCount(reason: String) throws -> Int {
        try scalar("SELECT count(*) FROM coverage_gaps WHERE reason = ?", strings: [reason])
    }

    public func sourceIDs() throws -> [String] {
        let statement = try prepare("SELECT DISTINCT source_id FROM observations ORDER BY source_id")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(columnString(statement, 0))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func recentObservations(limit: Int = 50) throws -> [StoredObservation] {
        let statement = try prepare("SELECT id, app_label, title, body, captured_at FROM observations ORDER BY id DESC LIMIT ?",
                                    numbers: [Double(max(1, min(limit, 200)))])
        defer { sqlite3_finalize(statement) }
        var result: [StoredObservation] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(StoredObservation(id: sqlite3_column_int64(statement, 0),
                          appLabel: columnString(statement, 1), title: columnString(statement, 2),
                          body: columnString(statement, 3), capturedAt: sqlite3_column_double(statement, 4)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func appSummaries() throws -> [AppCaptureSummary] {
        let statement = try prepare("SELECT app_label, count(*), max(captured_at) FROM observations GROUP BY app_label ORDER BY app_label")
        defer { sqlite3_finalize(statement) }
        var result: [AppCaptureSummary] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(AppCaptureSummary(appLabel: columnString(statement, 0),
                          count: Int(sqlite3_column_int64(statement, 1)),
                          lastCapturedAt: sqlite3_column_double(statement, 2)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    private func columnString(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        return String(decoding: bytes, as: UTF8.self)
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try operation()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func failure() -> StoreError {
        StoreError(description: String(cString: sqlite3_errmsg(database)))
    }

    // These bind parameters in SQL order. Text and numbers remain bound values.
    private func prepare(_ sql: String, numbersFirst: [Double] = [],
                         strings: [String?] = [], numbers: [Double] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement = statement else { throw failure() }
        func checkBinding(_ result: Int32) throws {
            guard result == SQLITE_OK else {
                let error = failure()
                sqlite3_finalize(statement)
                throw error
            }
        }
        var index: Int32 = 1
        for number in numbersFirst {
            try checkBinding(sqlite3_bind_double(statement, index, number))
            index += 1
        }
        for string in strings {
            if let string = string {
                guard let byteCount = Int32(exactly: string.utf8.count) else {
                    sqlite3_finalize(statement)
                    throw StoreError(description: "Text exceeds SQLite binding size")
                }
                let result = string.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, byteCount, transient)
                }
                try checkBinding(result)
            } else {
                try checkBinding(sqlite3_bind_null(statement, index))
            }
            index += 1
        }
        for number in numbers {
            try checkBinding(sqlite3_bind_double(statement, index, number))
            index += 1
        }
        return statement
    }

    private func execute(_ sql: String, numbersFirst: [Double] = [],
                         strings: [String?] = [], numbers: [Double] = []) throws {
        // sqlite3_exec handles the multi-statement initial schema only.
        if strings.isEmpty && numbersFirst.isEmpty && numbers.isEmpty {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
            return
        }
        let statement = try prepare(sql, numbersFirst: numbersFirst, strings: strings, numbers: numbers)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func scalar(_ sql: String, strings: [String?] = []) throws -> Int {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

public extension CaptureStore {
    func inbox(_ query: InboxQuery) throws -> [InboxEntry] {
        var filters: [String] = []
        var arguments: [String?] = []
        let app = "CASE WHEN o.app_label IN ('X', 'Twitter') THEN 'X' ELSE coalesce(nullif(o.app_label, ''), 'Unknown app') END"
        switch query.scope {
        case .inbox(let appLabel, let saved):
            if let appLabel {
                filters.append("\(app) = ?")
                arguments.append(appLabel)
            }
            if saved { filters.append("w.saved = 1") }
        case .person(let id):
            filters.append("p.id = ?")
            arguments.append(id)
        case .followUps:
            filters.append("w.due_at IS NOT NULL AND w.done = 0")
        }
        if !query.search.isEmpty {
            let term = query.search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let fields = [app, "o.title", "o.subtitle", "o.body", "p.display_name"]
            filters.append("(" + fields.map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")")
            arguments.append(contentsOf: fields.map { _ in "%\(term)%" })
        }
        let whereClause = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        let order = query.scope == .followUps ? "w.due_at, o.id DESC" : "o.id DESC"
        return try readRows("""
            SELECT o.id, \(app), o.title, o.subtitle, o.body, o.captured_at,
                   w.saved, w.due_at, w.done, p.id, p.display_name
            FROM observations o
            LEFT JOIN observation_work w ON w.observation_id = o.id
            LEFT JOIN person_observations l ON l.observation_id = o.id
            LEFT JOIN people p ON p.id = l.person_id
            \(whereClause) ORDER BY \(order) LIMIT ?
            """, strings: arguments, numbers: [Double(max(1, min(query.limit, 1001)))]) { row in
                InboxEntry(id: sqlite3_column_int64(row, 0), app: columnString(row, 1),
                           title: columnString(row, 2), subtitle: columnString(row, 3),
                           body: columnString(row, 4), capturedAt: sqlite3_column_double(row, 5),
                           saved: sqlite3_column_int(row, 6) != 0,
                           dueAt: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : sqlite3_column_double(row, 7),
                           done: sqlite3_column_int(row, 8) != 0,
                           personID: sqlite3_column_type(row, 9) == SQLITE_NULL ? nil : columnString(row, 9),
                           personName: columnString(row, 10))
            }
    }

    func people() throws -> [RolodexPerson] {
        try readRows("SELECT id, display_name FROM people ORDER BY display_name COLLATE NOCASE, id") { row in
            RolodexPerson(id: columnString(row, 0), name: columnString(row, 1))
        }
    }

    func identities(for person: String) throws -> [RolodexIdentity] {
        try readRows("SELECT id, platform, identifier FROM identities WHERE person_id = ? ORDER BY platform, identifier",
                     strings: [person]) { row in
            RolodexIdentity(id: columnString(row, 0), platform: columnString(row, 1), identifier: columnString(row, 2))
        }
    }

    func createPerson(name: String, linking observation: Int64? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError(description: "Enter a name for this person.") }
        let id = UUID().uuidString
        try transaction {
            try execute("INSERT INTO people (id, display_name) VALUES (?, ?)", strings: [id, name])
            if let observation { try link(observation, to: id) }
        }
        return id
    }

    func link(_ observation: Int64, to person: String?) throws {
        if let person {
            try execute("""
                INSERT INTO person_observations (observation_id, person_id, method) VALUES (?, ?, 'manual')
                ON CONFLICT(observation_id) DO UPDATE SET person_id = excluded.person_id, method = 'manual'
                """, strings: [String(observation), person])
        } else {
            try execute("DELETE FROM person_observations WHERE observation_id = ?", strings: [String(observation)])
        }
    }

    func addIdentity(person: String, platform: String, identifier: String) throws {
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        var identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if platform == "X" {
            if identifier.hasPrefix("@") { identifier.removeFirst() }
            identifier = identifier.lowercased()
        } else if platform == "Gmail" { identifier = identifier.lowercased() }
        guard !platform.isEmpty, !identifier.isEmpty else {
            throw StoreError(description: "Enter an app and a handle or address.")
        }
        try transaction {
            let owners = try readRows("SELECT person_id FROM identities WHERE platform = ? AND identifier = ?",
                                     strings: [platform, identifier]) { columnString($0, 0) }
            if let owner = owners.first {
                guard owner == person else { throw StoreError(description: "This identity is already in the Rolodex.") }
                return
            }
            try execute("INSERT INTO identities (id, person_id, platform, identifier) VALUES (?, ?, ?, ?)",
                        strings: [UUID().uuidString, person, platform, identifier])
        }
    }

    func removeIdentity(_ identity: String, person: String) throws {
        try execute("DELETE FROM identities WHERE id = ? AND person_id = ?", strings: [identity, person])
    }

    func setSaved(_ observation: Int64, saved: Bool) throws {
        try execute("""
            INSERT INTO observation_work (observation_id, saved) VALUES (?, ?)
            ON CONFLICT(observation_id) DO UPDATE SET saved = excluded.saved
            """, strings: [String(observation)], numbers: [saved ? 1 : 0])
    }

    func schedule(_ observation: Int64, dueAt: Double) throws {
        guard dueAt.isFinite else { throw StoreError(description: "Choose a valid due date.") }
        try execute("""
            INSERT INTO observation_work (observation_id, due_at) VALUES (?, ?)
            ON CONFLICT(observation_id) DO UPDATE SET due_at = excluded.due_at, done = 0
            """, strings: [String(observation)], numbers: [dueAt])
    }

    func complete(_ observation: Int64) throws {
        try execute("UPDATE observation_work SET done = 1 WHERE observation_id = ? AND due_at IS NOT NULL",
                    strings: [String(observation)])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This alert has no scheduled follow-up.") }
    }

    private func readRows<T>(_ sql: String, strings: [String?] = [], numbers: [Double] = [],
                             map: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, strings: strings, numbers: numbers)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(map(statement))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return rows
    }
}
