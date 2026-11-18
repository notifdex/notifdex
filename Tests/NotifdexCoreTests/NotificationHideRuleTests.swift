import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class NotificationHideRuleTests: XCTestCase {
    func testMigrateGmailSubjectAndKeepIndependentHideReasonsAcrossReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("capture.db").path
        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            for name in ["schema", "inbox-work", "filters", "person-matches", "person-notes", "flags"] {
                XCTAssertEqual(sqlite3_exec(db, try CaptureStore.schema(named: name), nil, nil, nil), SQLITE_OK)
            }
            let fixture = """
                PRAGMA user_version = 6;
                INSERT INTO capture_runs VALUES ('old', 1, 2, 2);
                INSERT INTO observations VALUES (42, 'phone', 'banner', 'old', 2, 'iphone', 'Gmail',
                    'CI Bot', '', 'First PR', 'Gmail, CI Bot, First PR, from iPhone', 1);
                INSERT INTO inbox_filters VALUES (9, 'Gmail', 'First PR');
                INSERT INTO hidden_observations VALUES (42);
                INSERT INTO flagged_observations VALUES (42);
                """
            XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        }

        let title = InboxRuleMatch(app: "Gmail", field: .title, text: "CI Bot")
        let body = InboxRuleMatch(app: "Gmail", field: .body, text: "First PR")
        do {
            let store = try CaptureStore(path: path)
            let legacy = try XCTUnwrap(store.inboxFilters().first)
            XCTAssertEqual(legacy.match, body)
            XCTAssertEqual(legacy.id, 9)
            XCTAssertEqual(try store.previewHideRule(title), 1)
            XCTAssertTrue(try store.addHideRule(title))
            XCTAssertFalse(try store.addHideRule(title))

            let run = try store.startRun(at: 3)
            try store.record(Observation(sourceID: "phone", sourceEventID: "later-gmail", capturedAt: 4,
                                         description: "Gmail, CI Bot, Second PR, from iPhone",
                                         title: "CI Bot", body: "Second PR"), runID: run)
            try store.record(Observation(sourceID: "phone", sourceEventID: "other-app", capturedAt: 5,
                                         description: "X, CI Bot, First PR, from iPhone",
                                         title: "CI Bot", body: "First PR"), runID: run)
        }

        let store = try CaptureStore(path: path)
        XCTAssertEqual(try store.inbox(InboxQuery()).map(\.app), ["X"])
        let hidden = try store.inbox(InboxQuery(scope: .hidden(app: "Gmail")))
        XCTAssertEqual(hidden.map(\.body), ["Second PR", "First PR"])
        XCTAssertTrue(hidden.allSatisfy(\.titleFiltered))
        XCTAssertEqual(hidden.last?.bodyFiltered, true)

        try store.removeHideRule(title)
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.id), [42])
        try store.removeHideRule(body)
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.id), [42])
        try store.restoreAlert(42)
        XCTAssertTrue(try store.inbox(InboxQuery(scope: .hidden(app: nil))).isEmpty)
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .flagged(app: nil))).map(\.id), [42])
    }

    func testExactBodyAcrossXAliasesAndTitleIsSeparate() throws {
        let store = try CaptureStore(path: ":memory:")
        let run = try store.startRun(at: 1)
        let captures = [
            ("Twitter", "Alex", "Digest"),
            ("X", "Digest", "Different"),
            ("X", "Alex", "Digest "),
            ("Gmail", "Alex", "Digest"),
        ]
        for (index, parts) in captures.enumerated() {
            let (app, title, body) = parts
            try store.record(Observation(sourceID: "phone", sourceEventID: String(index), capturedAt: 2,
                                         description: "\(app), \(title), \(body), from iPhone",
                                         title: title, body: body), runID: run)
        }

        let body = InboxRuleMatch(app: "X", field: .body, text: "Digest")
        XCTAssertThrowsError(try store.addHideRule(InboxRuleMatch(app: "X", field: .title, text: " \n")))
        XCTAssertEqual(try store.previewHideRule(body), 1)
        XCTAssertTrue(try store.addHideRule(body))
        XCTAssertEqual(try store.inbox(InboxQuery()).map(\.body), ["Digest", "Digest ", "Different"])
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).first?.bodyFiltered, true)
    }
}
