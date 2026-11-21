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
            guard (0...10).contains(version) else {
                throw StoreError(description: "Unsupported database version \(version)")
            }
            if version < 10 {
                try transaction {
                    // Recheck under the write lock if another process opened concurrently.
                    let current = try scalar("PRAGMA user_version")
                    guard (0...10).contains(current) else {
                        throw StoreError(description: "Unsupported database version \(current)")
                    }
                    if current == 0 {
                        guard try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                            throw StoreError(description: "Expected a new empty Notifdex database")
                        }
                        try execute(Self.schema(named: "schema"))
                    }
                    if current == 0 || current == 1 {
                        try execute(Self.schema(named: "inbox-work"))
                    }
                    if current < 3 {
                        try execute(Self.schema(named: "filters"))
                    }
                    if current < 4 {
                        try execute(Self.schema(named: "person-matches"))
                    }
                    if current < 5 {
                        try execute(Self.schema(named: "person-notes"))
                    }
                    if current < 6 {
                        try execute(Self.schema(named: "flags"))
                    }
                    if current < 7 {
                        try execute(Self.schema(named: "hide-rules"))
                    }
                    if current < 8 {
                        try execute(Self.schema(named: "relationship-templates"))
                    }
                    if current < 9 {
                        try execute(Self.schema(named: "workspaces"))
                    }
                    if current < 10 {
                        try execute(Self.schema(named: "notebook"))
                        try execute("PRAGMA user_version = 10")
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

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
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
    private static let appCategory = "CASE WHEN o.app_label IN ('X', 'Twitter') THEN 'X' ELSE coalesce(nullif(o.app_label, ''), 'Unknown app') END"

    private static let matchConflict = """
        EXISTS (
            SELECT 1 FROM observations o
            JOIN person_observations conflicting ON conflicting.observation_id = o.id
            WHERE o.title = m.title AND \(appCategory) = m.app AND conflicting.person_id <> m.person_id
        )
        """

    func personNotes(for person: String) throws -> [PersonNote] {
        try readRows("""
            SELECT id, title, body, created_at, updated_at FROM person_notes
            WHERE person_id = ? ORDER BY created_at DESC, id
            """, strings: [person]) { row in
                PersonNote(id: columnString(row, 0), title: columnString(row, 1), body: columnString(row, 2),
                           createdAt: sqlite3_column_double(row, 3), updatedAt: sqlite3_column_double(row, 4))
            }
    }

    @discardableResult
    func addPersonNote(person: String, title: String = "", body: String, at time: Double) throws -> String {
        try Self.validateNote(body, at: time)
        let id = UUID().uuidString
        try execute("""
            INSERT INTO person_notes (id, person_id, title, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            """, strings: [id, person, title.trimmingCharacters(in: .whitespacesAndNewlines), body], numbers: [time, time])
        return id
    }

    func updatePersonNote(_ id: String, person: String, title: String? = nil, body: String, at time: Double) throws {
        try Self.validateNote(body, at: time)
        try execute("""
            UPDATE person_notes SET updated_at = max(updated_at, ?), title = coalesce(?, title), body = ?
            WHERE id = ? AND person_id = ?
            """, numbersFirst: [time], strings: [title?.trimmingCharacters(in: .whitespacesAndNewlines), body, id, person])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This note no longer exists for this person.") }
    }

    func deletePersonNote(_ id: String, person: String) throws {
        try execute("DELETE FROM person_notes WHERE id = ? AND person_id = ?", strings: [id, person])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This note no longer exists for this person.") }
    }

    func noteFolders() throws -> [NoteFolder] {
        try readRows("SELECT id, name FROM note_folders ORDER BY name COLLATE NOCASE, id") { row in
            NoteFolder(id: columnString(row, 0), name: columnString(row, 1))
        }
    }

    @discardableResult
    func saveNoteFolder(_ id: String? = nil, name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError(description: "Enter a folder name.") }
        if let id {
            try execute("UPDATE note_folders SET name = ? WHERE id = ?", strings: [name, id])
            guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This folder no longer exists.") }
            return id
        }
        let newID = UUID().uuidString
        try execute("INSERT INTO note_folders (id, name) VALUES (?, ?)", strings: [newID, name])
        return newID
    }

    func deleteNoteFolder(_ id: String) throws {
        // SQLite clears the folder reference on each note in the same write.
        try execute("DELETE FROM note_folders WHERE id = ?", strings: [id])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This folder no longer exists.") }
    }

    func personalNotes() throws -> [PersonalNote] {
        try readRows("""
            SELECT id, folder_id, title, body, created_at, updated_at FROM personal_notes
            ORDER BY updated_at DESC, id
            """) { row in
                PersonalNote(id: columnString(row, 0),
                             folderID: sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : columnString(row, 1),
                             title: columnString(row, 2), body: columnString(row, 3),
                             createdAt: sqlite3_column_double(row, 4), updatedAt: sqlite3_column_double(row, 5))
            }
    }

    @discardableResult
    func savePersonalNote(_ id: String? = nil, folderID: String?, title: String, body: String, at time: Double) throws -> String {
        try Self.validateNote(body, at: time)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id {
            try execute("""
                UPDATE personal_notes SET updated_at = max(updated_at, ?), folder_id = ?, title = ?, body = ?
                WHERE id = ?
                """, numbersFirst: [time], strings: [folderID, title, body, id])
            guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This note no longer exists.") }
            return id
        }
        let newID = UUID().uuidString
        try execute("""
            INSERT INTO personal_notes (id, folder_id, title, body, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, strings: [newID, folderID, title, body], numbers: [time, time])
        return newID
    }

    func deletePersonalNote(_ id: String) throws {
        try execute("DELETE FROM personal_notes WHERE id = ?", strings: [id])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "This note no longer exists.") }
    }

    private static func validateNote(_ body: String, at time: Double) throws {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError(description: "Enter a note before saving.")
        }
        guard time.isFinite else { throw StoreError(description: "Invalid note timestamp.") }
    }

    func inbox(_ query: InboxQuery) throws -> [InboxEntry] {
        try inboxRows(query, selectedID: nil)
    }

    /// Keep an open alert available when reading it removes it from the filtered list.
    func selectedInboxEntry(_ id: Int64, in query: InboxQuery) throws -> InboxEntry? {
        var lookup = query
        lookup.readFilter = .all
        lookup.limit = 1
        return try inboxRows(lookup, selectedID: id).first
    }

    private func inboxRows(_ query: InboxQuery, selectedID: Int64?) throws -> [InboxEntry] {
        var filters: [String] = []
        var arguments: [String?] = []
        let app = Self.appCategory
        // The probe exposed Gmail's subject as preview text. Other apps need
        // an observed subject mapping before they can offer a subject rule.
        let subject = "CASE WHEN o.app_label = 'Gmail' THEN o.body END"
        let individuallyHidden = "EXISTS (SELECT 1 FROM hidden_observations h WHERE h.observation_id = o.id)"
        func hasHideRule(for field: InboxRuleMatch.Field) -> String {
            let column = field.rawValue
            return """
                EXISTS (SELECT 1 FROM inbox_filters f
                        WHERE f.app = \(app) AND f.field = '\(column)' AND f.value = o.\(column))
                """
        }
        let titleHidden = hasHideRule(for: .title)
        let bodyHidden = hasHideRule(for: .body)
        let hidden = "(\(individuallyHidden) OR \(titleHidden) OR \(bodyHidden))"
        let read = "EXISTS (SELECT 1 FROM read_observations r WHERE r.observation_id = o.id)"
        let flagged = "EXISTS (SELECT 1 FROM flagged_observations f WHERE f.observation_id = o.id)"
        switch query.scope {
        case .inbox(let appLabel, let saved):
            if let appLabel {
                filters.append("\(app) = ?")
                arguments.append(appLabel)
            }
            if saved { filters.append("w.saved = 1") }
            else { filters.append("NOT \(hidden)") }
        case .flagged(let appLabel):
            filters.append("\(flagged) AND NOT \(hidden)")
            if let appLabel {
                filters.append("\(app) = ?")
                arguments.append(appLabel)
            }
        case .hidden(let appLabel):
            filters.append(hidden)
            if let appLabel {
                filters.append("\(app) = ?")
                arguments.append(appLabel)
            }
        case .person(let id):
            filters.append("p.id = ?")
            arguments.append(id)
        case .followUps:
            filters.append("w.due_at IS NOT NULL AND w.done = 0")
        }
        if let workspace = query.workspaceID {
            if case .person = query.scope {
                // Unassigned alerts follow the linked person's membership in this view.
                filters.append("""
                    (route.workspace_id IS NULL OR route.workspace_id = ?)
                    AND EXISTS (SELECT 1 FROM person_workspaces pw
                                WHERE pw.person_id = p.id AND pw.workspace_id = ?)
                    """)
                arguments.append(contentsOf: [workspace, workspace])
            } else {
                filters.append("route.workspace_id = ?")
                arguments.append(workspace)
            }
        }
        switch query.readFilter {
        case .all: break
        case .unread: filters.append("NOT (\(read))")
        case .read: filters.append(read)
        }
        if let selectedID {
            filters.append("o.id = ?")
            arguments.append(String(selectedID))
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
        let order: String
        switch query.scope {
        case .inbox(_, false), .flagged:
            let direction = query.order == .newestFirst ? "DESC" : "ASC"
            order = "o.captured_at \(direction), o.id \(direction)"
        case .followUps: order = "w.due_at, o.id DESC"
        default: order = "o.id DESC"
        }
        return try readRows("""
            SELECT o.id, \(app), o.title, o.subtitle, o.body, o.captured_at,
                   w.saved, w.due_at, w.done, p.id, p.display_name,
                   \(subject), \(individuallyHidden), \(titleHidden), \(bodyHidden),
                   \(read), m.id, \(flagged), route.workspace_id
            FROM observations o
            LEFT JOIN observation_workspaces route ON route.observation_id = o.id
            LEFT JOIN observation_work w ON w.observation_id = o.id
            LEFT JOIN person_observations l ON l.observation_id = o.id
            LEFT JOIN person_match_rules m
              ON l.person_id IS NULL AND m.app = \(app) AND m.title = o.title
              AND o.id > m.after_observation_id AND NOT (\(Self.matchConflict))
              AND NOT EXISTS (SELECT 1 FROM person_match_exclusions e WHERE e.observation_id = o.id)
            LEFT JOIN people p ON p.id = coalesce(l.person_id, m.person_id)
            \(whereClause) ORDER BY \(order) LIMIT ?
            """, strings: arguments, numbers: [Double(max(1, min(query.limit, 1001)))]) { row in
                InboxEntry(id: sqlite3_column_int64(row, 0), app: columnString(row, 1),
                           title: columnString(row, 2), subtitle: columnString(row, 3),
                           body: columnString(row, 4), capturedAt: sqlite3_column_double(row, 5),
                           saved: sqlite3_column_int(row, 6) != 0,
                           dueAt: sqlite3_column_type(row, 7) == SQLITE_NULL ? nil : sqlite3_column_double(row, 7),
                           done: sqlite3_column_int(row, 8) != 0,
                           personID: sqlite3_column_type(row, 9) == SQLITE_NULL ? nil : columnString(row, 9),
                           personName: columnString(row, 10), subject: columnString(row, 11),
                           individuallyHidden: sqlite3_column_int(row, 12) != 0,
                           titleFiltered: sqlite3_column_int(row, 13) != 0,
                           bodyFiltered: sqlite3_column_int(row, 14) != 0,
                           isRead: sqlite3_column_int(row, 15) != 0,
                           isFlagged: sqlite3_column_int(row, 17) != 0,
                           personRuleID: sqlite3_column_type(row, 16) == SQLITE_NULL ? nil : columnString(row, 16),
                           workspaceID: sqlite3_column_type(row, 18) == SQLITE_NULL ? nil : columnString(row, 18))
            }
    }

    func setRead(_ observation: Int64, read: Bool) throws {
        let sql = read
            ? "INSERT INTO read_observations VALUES (?) ON CONFLICT DO NOTHING"
            : "DELETE FROM read_observations WHERE observation_id = ?"
        try execute(sql, strings: [String(observation)])
    }

    func setFlag(_ observation: Int64, flagged: Bool) throws {
        let sql = flagged
            ? "INSERT INTO flagged_observations VALUES (?) ON CONFLICT DO NOTHING"
            : "DELETE FROM flagged_observations WHERE observation_id = ?"
        try execute(sql, strings: [String(observation)])
    }

    func hideAlert(_ observation: Int64) throws {
        try execute("INSERT INTO hidden_observations VALUES (?) ON CONFLICT DO NOTHING",
                    strings: [String(observation)])
    }

    func restoreAlert(_ observation: Int64) throws {
        try execute("DELETE FROM hidden_observations WHERE observation_id = ?", strings: [String(observation)])
    }

    func hideSubject(app: String, subject: String) throws {
        guard app == "Gmail", !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError(description: "This alert has no supported subject.")
        }
        try addHideRule(InboxRuleMatch(app: app, field: .body, text: subject))
    }

    func restoreSubject(app: String, subject: String) throws {
        guard app == "Gmail" else { return }
        try removeHideRule(InboxRuleMatch(app: app, field: .body, text: subject))
    }

    func previewHideRule(_ match: InboxRuleMatch) throws -> Int {
        try validateHideRule(match)
        return try scalar("""
            SELECT count(*) FROM observations o WHERE \(Self.appCategory) = ? AND o.\(match.field.rawValue) = ?
            """, strings: [match.app, match.text])
    }

    @discardableResult
    func addHideRule(_ match: InboxRuleMatch) throws -> Bool {
        try validateHideRule(match)
        try execute("INSERT INTO inbox_filters (app, field, value) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                    strings: [match.app, match.field.rawValue, match.text])
        return sqlite3_changes(database) == 1
    }

    func removeHideRule(_ match: InboxRuleMatch) throws {
        try execute("DELETE FROM inbox_filters WHERE app = ? AND field = ? AND value = ?",
                    strings: [match.app, match.field.rawValue, match.text])
    }

    func inboxFilters() throws -> [InboxFilter] {
        try readRows("SELECT id, app, field, value FROM inbox_filters ORDER BY app, field, value") { row in
            let field: InboxRuleMatch.Field = columnString(row, 2) == "title" ? .title : .body
            let match = InboxRuleMatch(app: columnString(row, 1), field: field, text: columnString(row, 3))
            return InboxFilter(id: sqlite3_column_int64(row, 0), match: match)
        }
    }

    private func validateHideRule(_ match: InboxRuleMatch) throws {
        guard !match.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, match.app != "Unknown app",
              !match.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError(description: "Choose an alert with a known app and nonempty text.")
        }
    }

    func people(in workspace: String? = nil) throws -> [PersonRecord] {
        let membership = workspace == nil ? "" : """
            WHERE EXISTS (SELECT 1 FROM person_workspaces pw WHERE pw.person_id = people.id AND pw.workspace_id = ?)
            """
        return try readRows("""
            SELECT id, display_name FROM people \(membership) ORDER BY display_name COLLATE NOCASE, id
            """, strings: workspace.map { [$0] } ?? []) { row in
                PersonRecord(id: columnString(row, 0), name: columnString(row, 1))
            }
    }

    func workspaces() throws -> [WorkspaceRecord] {
        try readRows("SELECT id, name FROM workspaces ORDER BY name COLLATE NOCASE, id") { row in
            WorkspaceRecord(id: columnString(row, 0), name: columnString(row, 1))
        }
    }

    @discardableResult
    func createWorkspace(name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.utf8.contains(0), name.caseInsensitiveCompare("All People") != .orderedSame,
              name.caseInsensitiveCompare("Unassigned") != .orderedSame else {
            throw StoreError(description: "Choose a workspace name other than All People or Unassigned.")
        }
        let id = UUID().uuidString
        try execute("""
            INSERT INTO workspaces (id, name) VALUES (?, ?) ON CONFLICT(name) DO NOTHING
            """, strings: [id, name])
        guard sqlite3_changes(database) == 1 else { throw StoreError(description: "A workspace already uses that name.") }
        return id
    }

    func workspaceIDs(for person: String) throws -> Set<String> {
        Set(try readRows("SELECT workspace_id FROM person_workspaces WHERE person_id = ?",
                         strings: [person]) { columnString($0, 0) })
    }

    func setWorkspaceMembership(person: String, workspace: String, isMember: Bool) throws {
        if isMember {
            try execute("""
                INSERT INTO person_workspaces (person_id, workspace_id) VALUES (?, ?)
                ON CONFLICT(person_id, workspace_id) DO NOTHING
                """, strings: [person, workspace])
        } else {
            try execute("DELETE FROM person_workspaces WHERE person_id = ? AND workspace_id = ?",
                        strings: [person, workspace])
        }
    }

    func setAlertWorkspace(_ observation: Int64, to workspace: String?) throws {
        if let workspace {
            try execute("""
                INSERT INTO observation_workspaces (observation_id, workspace_id) VALUES (?, ?)
                ON CONFLICT(observation_id) DO UPDATE SET workspace_id = excluded.workspace_id
                """, strings: [String(observation), workspace])
        } else {
            try execute("DELETE FROM observation_workspaces WHERE observation_id = ?", strings: [String(observation)])
        }
    }

    func identities(for person: String) throws -> [PersonIdentity] {
        try readRows("SELECT id, platform, identifier FROM identities WHERE person_id = ? ORDER BY platform, identifier",
                     strings: [person]) { row in
            PersonIdentity(id: columnString(row, 0), platform: columnString(row, 1), identifier: columnString(row, 2))
        }
    }

    func createPerson(name: String, linking observation: Int64? = nil, workspace: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError(description: "Enter a name for this person.") }
        let id = UUID().uuidString
        try transaction {
            try execute("INSERT INTO people (id, display_name) VALUES (?, ?)", strings: [id, name])
            if let observation { try link(observation, to: id) }
            if let workspace { try setWorkspaceMembership(person: id, workspace: workspace, isMember: true) }
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
            try transaction {
                try execute("DELETE FROM person_observations WHERE observation_id = ?", strings: [String(observation)])
                try execute("INSERT INTO person_match_exclusions VALUES (?) ON CONFLICT DO NOTHING",
                            strings: [String(observation)])
            }
        }
    }

    func previewPersonMatch(for observation: Int64) throws -> PersonMatchPreview {
        let source = try readRows("""
            SELECT \(Self.appCategory), o.title, p.id, p.display_name
            FROM observations o JOIN person_observations l ON l.observation_id = o.id
            JOIN people p ON p.id = l.person_id WHERE o.id = ?
            """, strings: [String(observation)]) { row in
                (columnString(row, 0), columnString(row, 1), columnString(row, 2), columnString(row, 3))
            }
        guard let (app, title, person, name) = source.first, app != "Unknown app",
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError(description: "Link the alert to a person first. A rule needs an app and a title.")
        }
        if try scalar("SELECT count(*) FROM person_match_rules WHERE app = ? AND title = ?", strings: [app, title]) > 0 {
            throw StoreError(description: "A rule already uses this app and title. Remove the existing rule before creating another.")
        }
        let conflicts = try scalar("""
            SELECT count(*) FROM observations o
            JOIN person_observations l ON l.observation_id = o.id
            WHERE \(Self.appCategory) = ? AND o.title = ? AND l.person_id <> ?
            """, strings: [app, title, person])
        guard conflicts == 0 else {
            throw StoreError(description: "This app and title are linked to more than one person. Keep linking these alerts individually.")
        }
        let count = try scalar("""
            SELECT count(*) FROM observations o
            WHERE \(Self.appCategory) = ? AND o.title = ?
              AND NOT EXISTS (SELECT 1 FROM person_observations l WHERE l.observation_id = o.id)
              AND NOT EXISTS (SELECT 1 FROM person_match_exclusions e WHERE e.observation_id = o.id)
            """, strings: [app, title])
        return PersonMatchPreview(observationID: observation, app: app, title: title, personID: person,
                                  personName: name, existingCount: count)
    }

    func confirmPersonMatch(_ preview: PersonMatchPreview, includeExisting: Bool) throws {
        try transaction {
            let current = try previewPersonMatch(for: preview.observationID)
            guard current.app == preview.app, current.title == preview.title,
                  current.personID == preview.personID else {
                throw StoreError(description: "The alert link changed. Review the match again.")
            }
            let cutoff = includeExisting ? 0 : try scalar("SELECT coalesce(max(id), 0) FROM observations")
            try execute("""
                INSERT INTO person_match_rules (id, app, title, person_id, after_observation_id)
                VALUES (?, ?, ?, ?, ?)
                """, strings: [UUID().uuidString, current.app, current.title, current.personID, String(cutoff)])
        }
    }

    func personMatchRules(for person: String) throws -> [PersonMatchRule] {
        try readRows("""
            SELECT m.id, m.app, m.title, \(Self.matchConflict)
            FROM person_match_rules m WHERE m.person_id = ? ORDER BY m.app, m.title
            """, strings: [person]) { row in
            PersonMatchRule(id: columnString(row, 0), app: columnString(row, 1),
                            title: columnString(row, 2), hasConflict: sqlite3_column_int(row, 3) != 0)
        }
    }

    func removePersonMatchRule(_ id: String) throws {
        try execute("DELETE FROM person_match_rules WHERE id = ?", strings: [id])
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
                guard owner == person else { throw StoreError(description: "This identity is already linked to another person.") }
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

public extension CaptureStore {
    @discardableResult
    func installTemplate(_ definition: RelationshipTemplate) throws -> RelationshipTemplate {
        try transaction {
            if let existing = try installedTemplate(matching: definition) { return existing }
            try execute("""
                INSERT INTO relationship_templates (template_id, version, definition) VALUES (?, ?, ?)
                """, strings: [definition.id, String(definition.version), try definition.encodedDefinition()])
            return definition
        }
    }

    func templateAssignment(for person: String) throws -> RelationshipTemplateAssignment? {
        let rows = try readRows("""
            SELECT t.definition, p.stage_id, m.milestone_id, m.completed
            FROM person_templates p
            JOIN relationship_templates t USING (template_id, version)
            LEFT JOIN person_template_milestones m USING (person_id)
            WHERE p.person_id = ?
            """, strings: [person]) { row in
                (definition: columnString(row, 0), stage: columnString(row, 1),
                 milestone: columnString(row, 2), completed: sqlite3_column_int(row, 3) == 1)
            }
        guard let first = rows.first else { return nil }
        return RelationshipTemplateAssignment(
            definition: try RelationshipTemplate.decode(Data(first.definition.utf8)),
            stageID: first.stage,
            completedMilestones: Set(rows.filter { $0.completed }.map { $0.milestone })
        )
    }

    @discardableResult
    func applyTemplate(_ definition: RelationshipTemplate, to person: String) throws -> RelationshipTemplateAssignment {
        try transaction {
            if let existing = try templateAssignment(for: person) {
                guard existing.definition.id == definition.id, existing.definition.version == definition.version else {
                    throw RelationshipTemplateError.assignmentConflict
                }
                guard existing.definition == definition else { throw RelationshipTemplateError.versionConflict }
                return existing
            }
            guard let installed = try installedTemplate(matching: definition) else {
                throw RelationshipTemplateError.versionNotInstalled
            }
            let initialStage = installed.stages[0].id
            try execute("""
                INSERT INTO person_templates (person_id, template_id, version, stage_id) VALUES (?, ?, ?, ?)
                """, strings: [person, installed.id, String(installed.version), initialStage])
            for milestone in installed.milestones {
                try execute("""
                    INSERT INTO person_template_milestones (person_id, milestone_id, completed) VALUES (?, ?, 0)
                    """, strings: [person, milestone.id])
            }
            return RelationshipTemplateAssignment(definition: installed, stageID: initialStage, completedMilestones: [])
        }
    }

    func removeTemplate(_ definition: RelationshipTemplate, from person: String) throws {
        // The existing foreign key cascades the delete to this assignment's milestones.
        try execute("""
            DELETE FROM person_templates WHERE person_id = ? AND template_id = ? AND version = ?
            """, strings: [person, definition.id, String(definition.version)])
    }

    func setTemplateStage(_ stageID: String, for person: String) throws {
        try transaction {
            guard let assignment = try templateAssignment(for: person) else {
                throw RelationshipTemplateError.noAssignment
            }
            guard assignment.definition.stages.contains(where: { $0.id == stageID }) else {
                throw RelationshipTemplateError.unknownStage
            }
            try execute("UPDATE person_templates SET stage_id = ? WHERE person_id = ?",
                        strings: [stageID, person])
        }
    }

    func setTemplateMilestone(_ milestoneID: String, completed: Bool, for person: String) throws {
        try transaction {
            guard let assignment = try templateAssignment(for: person) else {
                throw RelationshipTemplateError.noAssignment
            }
            guard assignment.definition.milestones.contains(where: { $0.id == milestoneID }) else {
                throw RelationshipTemplateError.unknownMilestone
            }
            try execute("""
                UPDATE person_template_milestones SET completed = ? WHERE person_id = ? AND milestone_id = ?
                """, numbersFirst: [completed ? 1 : 0], strings: [person, milestoneID])
        }
    }

    private func installedTemplate(matching definition: RelationshipTemplate) throws -> RelationshipTemplate? {
        let stored = try readRows("""
            SELECT definition FROM relationship_templates WHERE template_id = ? AND version = ?
            """, strings: [definition.id, String(definition.version)]) { columnString($0, 0) }
        guard let json = stored.first else { return nil }
        let existing = try RelationshipTemplate.decode(Data(json.utf8))
        guard existing == definition else { throw RelationshipTemplateError.versionConflict }
        return existing
    }
}
