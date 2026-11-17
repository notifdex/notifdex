import Foundation
import CSQLite

public struct StoreError: Error, CustomStringConvertible {
    public let description: String
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
            guard version == 0 || version == 1 else {
                throw StoreError(description: "Unsupported database version \(version)")
            }
            if version == 0 {
                // Refuse accidental reuse of an old application database.
                guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                    throw StoreError(description: "Expected a new empty Notifdex database")
                }
                let url = Bundle.module.url(forResource: "schema", withExtension: "sql")!
                let schema = try String(contentsOf: url, encoding: .utf8)
                try transaction {
                    try execute(schema)
                    try execute("PRAGMA user_version = 1")
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
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
            try execute("UPDATE capture_runs SET ended_at = max(started_at, ?) WHERE ended_at IS NULL", numbers: [time])
            try execute("INSERT INTO capture_runs(id, started_at, heartbeat_at) VALUES (?, ?, ?)",
                        strings: [runID], numbers: [time, time])
            try openGap(runID: runID, reason: "startup_scan", at: time)
        }
        return runID
    }

    @discardableResult
    public func record(_ value: Observation, runID: String) throws -> Bool {
        var inserted = false
        try transaction {
            try heartbeat(runID: runID, at: value.capturedAt)
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
            inserted = sqlite3_changes(database) == 1
        }
        return inserted
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
