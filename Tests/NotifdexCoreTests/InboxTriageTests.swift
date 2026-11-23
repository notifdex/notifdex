import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class InboxTriageTests: XCTestCase {
    func testDateOrderAndFiltersApplyBeforeLimitAndSelectionCanRemainOpen() throws {
        let store = try CaptureStore(path: ":memory:")
        let run = try store.startRun(at: 1)
        func capture(_ body: String, app: String = "Gmail", at time: Double) throws {
            try store.record(Observation(sourceID: "fixture", sourceEventID: body, capturedAt: time,
                                         description: "\(app), Alex, \(body), from iPhone",
                                         title: "Alex", body: body), runID: run)
        }
        try capture("review newer", at: 20)
        try capture("review oldest", at: 5)
        try capture("review tie", at: 20)
        try capture("review other app", app: "X", at: 3)
        try capture("unrelated", at: 2)

        var query = InboxQuery(scope: .inbox(app: "Gmail", saved: false), search: "review",
                               limit: 1, readFilter: .unread, order: .oldestFirst)
        let oldest = try XCTUnwrap(store.inbox(query).first)
        XCTAssertEqual(oldest.body, "review oldest")
        try store.setRead(oldest.id, read: true)
        XCTAssertEqual(try store.inbox(query).first?.body, "review newer")
        XCTAssertEqual(try store.selectedInboxEntry(oldest.id, in: query)?.isRead, true)

        query.order = .newestFirst
        XCTAssertEqual(try store.inbox(query).first?.body, "review tie")
        query.readFilter = .read
        XCTAssertEqual(try store.inbox(query).map(\.id), [oldest.id])
        try store.setRead(oldest.id, read: false)
        XCTAssertTrue(try store.inbox(query).isEmpty)
        XCTAssertEqual(try store.selectedInboxEntry(oldest.id, in: query)?.isRead, false)
        query.search = "missing"
        XCTAssertNil(try store.selectedInboxEntry(oldest.id, in: query))
    }

    func testV5FlagsSurviveReopenAndHideWithoutChangingReadOrSaved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path
        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            for resource in ["schema", "inbox-work", "filters", "person-matches", "person-notes"] {
                let sql = try CaptureStore.schema(named: resource)
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
            let fixture = """
                PRAGMA user_version = 5;
                INSERT INTO capture_runs VALUES ('old', 1, 2, 2);
                INSERT INTO observations VALUES (42, 'phone', 'banner', 'old', 2, 'iphone',
                    'Gmail', 'Alex', '', 'Hello', 'Gmail, Alex, Hello, from iPhone', 1);
                INSERT INTO read_observations VALUES (42);
                INSERT INTO observation_work (observation_id, saved, due_at) VALUES (42, 1, 3);
                """
            XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        }
        let query = InboxQuery(scope: .flagged(app: "Gmail"), readFilter: .read)
        do {
            let store = try CaptureStore(path: path)
            XCTAssertTrue(try store.inbox(query).isEmpty)
            XCTAssertThrowsError(try store.setFlag(999, flagged: true))
            try store.setFlag(42, flagged: true)
            try store.setFlag(42, flagged: true)
            try store.hideAlert(42)
            try store.hideSubject(app: "Gmail", subject: "Hello")
            XCTAssertTrue(try store.inbox(query).isEmpty)
        }
        let store = try CaptureStore(path: path)
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).first?.isFlagged, true)
        try store.restoreAlert(42)
        XCTAssertTrue(try store.inbox(query).isEmpty)
        try store.restoreSubject(app: "Gmail", subject: "Hello")
        let flagged = try XCTUnwrap(store.inbox(query).first)
        XCTAssertEqual(flagged.id, 42)
        XCTAssertTrue(flagged.isRead)
        XCTAssertTrue(flagged.saved)
        XCTAssertEqual(flagged.dueAt, 3)
        try store.setFlag(42, flagged: false)
        try store.setFlag(42, flagged: false)
        XCTAssertTrue(try store.inbox(query).isEmpty)
        let retainedAfterUnflag = try XCTUnwrap(store.selectedInboxEntry(42, in: query))
        XCTAssertEqual(retainedAfterUnflag.id, 42)
        XCTAssertFalse(retainedAfterUnflag.isFlagged)
        try store.hideAlert(42)
        XCTAssertNil(try store.selectedInboxEntry(42, in: query))
        try store.restoreAlert(42)
        XCTAssertEqual(try store.inbox(InboxQuery()).first?.saved, true)
    }
}
