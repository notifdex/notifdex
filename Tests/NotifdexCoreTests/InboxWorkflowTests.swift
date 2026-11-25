import Foundation
import XCTest
@testable import NotifdexCore
import CSQLite

final class InboxWorkflowTests: XCTestCase {
    func testInboxToPersonToFollowUpSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        for (index, app) in ["Twitter", "Gmail", "X"].enumerated() {
            let body = index == 1 ? "100% ready" : "Hello"
            try store.record(Observation(sourceID: "fixture", sourceEventID: String(index),
                                         capturedAt: Double(index + 2),
                                         description: "\(app), Alex, \(body), from iPhone",
                                         title: "Alex", body: body), runID: run)
        }
        let inbox = try store.inbox(InboxQuery())
        XCTAssertEqual(inbox.map(\.app), ["X", "Gmail", "X"])
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .inbox(app: "X", saved: false))).count, 2)
        XCTAssertEqual(try store.inbox(InboxQuery(search: "%")).map(\.id), [inbox[1].id])
        XCTAssertTrue(try store.people().isEmpty)

        let mail = inbox[1].id
        let dm = inbox[2].id
        XCTAssertThrowsError(try store.createPerson(name: "Orphan", linking: Int64.max))
        XCTAssertTrue(try store.people().isEmpty)
        let alex = try store.createPerson(name: "Alex", linking: dm)
        let other = try store.createPerson(name: "Alex", linking: inbox[0].id)
        XCTAssertNotEqual(alex, other)
        try store.link(mail, to: alex)
        try store.addIdentity(person: alex, platform: "X", identifier: "@alex")
        try store.addIdentity(person: alex, platform: "X", identifier: "ALEX")
        XCTAssertThrowsError(try store.addIdentity(person: other, platform: "X", identifier: "@alex"))
        try store.setSaved(dm, saved: true)
        try store.schedule(dm, dueAt: 20)
        try store.schedule(dm, dueAt: 30)

        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(alex))).map(\.id), [mail, dm])
        XCTAssertEqual(try reopened.identities(for: alex).map(\.identifier), ["@alex"])
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .inbox(app: nil, saved: true))).map(\.id), [dm])
        let open = try XCTUnwrap(reopened.inbox(InboxQuery(scope: .followUps)).first)
        XCTAssertEqual(open.id, dm)
        XCTAssertEqual(open.dueAt, 30)
        XCTAssertEqual(open.personID, alex)
        try reopened.complete(dm)
        XCTAssertTrue(try reopened.inbox(InboxQuery(scope: .followUps)).isEmpty)
        try reopened.schedule(dm, dueAt: 40)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .followUps)).first?.dueAt, 40)
        try reopened.link(mail, to: nil)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(alex))).map(\.id), [dm])
        XCTAssertEqual(try reopened.observationCount(), 3)
    }

    func testVersionOneUpgradeRetainsObservationAndExistingPerson() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        do {
            defer { sqlite3_close(db); db = nil }
            // Use the same v1 schema shipped in the package.
            let schema = try CaptureStore.schema(named: "schema")
            XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
            let fixture = """
                PRAGMA user_version = 1;
                INSERT INTO capture_runs VALUES ('old', 1, 2, 2);
                INSERT INTO observations VALUES (42, 'phone', 'banner', 'old', 2, 'iphone',
                    'Gmail', 'Alex', '', 'Hello', 'Gmail, Alex, Hello, from iPhone', 1);
                INSERT INTO people VALUES ('alex', 'Alex');
                INSERT INTO person_observations VALUES (42, 'alex', 'manual');
                """
            XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        }
        let store = try CaptureStore(path: path)
        let item = try XCTUnwrap(store.inbox(InboxQuery()).first)
        XCTAssertEqual(item.id, 42)
        XCTAssertEqual(item.personID, "alex")
        XCTAssertEqual(item.body, "Hello")
        XCTAssertFalse(item.saved)
        XCTAssertNil(item.dueAt)
        try store.setSaved(item.id, saved: true)
        XCTAssertTrue(try CaptureStore(path: path).inbox(InboxQuery()).first?.saved == true)
    }
}
