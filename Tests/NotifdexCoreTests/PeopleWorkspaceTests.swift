import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class PeopleWorkspaceTests: XCTestCase {
    func testWorkspaceTimelineKeepsNewLinkedAlertsWithoutExplicitRouting() throws {
        let store = try CaptureStore(path: ":memory:")
        let run = try store.startRun(at: 1)
        func capture(_ tag: String, title: String = "Alex") throws -> Int64 {
            try store.record(Observation(sourceID: "phone", sourceEventID: tag, capturedAt: 2,
                                         description: "X, \(title), \(tag), from iPhone",
                                         title: title, body: tag), runID: run)
            return try XCTUnwrap(store.inbox(InboxQuery(search: tag)).first?.id)
        }
        let first = try capture("anchor-message")
        let person = try store.createPerson(name: "Alex", linking: first)
        try store.confirmPersonMatch(store.previewPersonMatch(for: first), includeExisting: false)
        let workspace = try store.createWorkspace(name: "Startup")
        let other = try store.createWorkspace(name: "Personal")
        try store.setWorkspaceMembership(person: person, workspace: workspace, isMember: true)
        let future = try capture("new-message")
        _ = try capture("unrelated-message", title: "Other sender")
        let query = InboxQuery(scope: .person(person), workspaceID: workspace)
        let entries = try store.inbox(query)
        XCTAssertEqual(entries.map(\.id), [future, first])
        XCTAssertNotNil(entries.first?.personRuleID)
        XCTAssertTrue(entries.allSatisfy { $0.workspaceID == nil })
        XCTAssertEqual(try store.selectedInboxEntry(first, in: query)?.id, first)

        try store.setAlertWorkspace(future, to: other)
        XCTAssertEqual(try store.inbox(query).map(\.id), [first])
        XCTAssertNil(try store.selectedInboxEntry(future, in: query))
        XCTAssertTrue(try store.inbox(InboxQuery(workspaceID: workspace)).isEmpty)
        try store.setAlertWorkspace(future, to: nil)
        XCTAssertEqual(try store.inbox(query).map(\.id), [future, first])
    }

    func testUpgradeReopenAndIndependentMembershipAndRouting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path
        var oldDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &oldDB), SQLITE_OK)
        do {
            defer { sqlite3_close(oldDB) }
            for name in ["schema", "inbox-work", "filters", "person-matches", "person-notes", "flags",
                         "hide-rules", "relationship-templates"] {
                XCTAssertEqual(sqlite3_exec(oldDB, try CaptureStore.schema(named: name), nil, nil, nil), SQLITE_OK)
            }
            let template = try RelationshipTemplate.bundledFounderOutreach().encodedDefinition()
            let fixture = """
                PRAGMA user_version = 8;
                INSERT INTO capture_runs VALUES ('run', 1, 5, 5);
                INSERT INTO observations VALUES
                    (1, 'test', '1', 'run', 2, 'iphone', 'X', 'Alex', '', 'Personal alert', '', 1),
                    (2, 'test', '2', 'run', 3, 'iphone', 'X', 'Alex', '', 'Startup alert', '', 1),
                    (3, 'test', '3', 'run', 4, 'iphone', 'X', 'Alex', '', 'Unassigned alert', '', 1);
                INSERT INTO people VALUES ('alex', 'Alex'), ('sam', 'Sam');
                INSERT INTO identities VALUES ('alex-x', 'alex', 'X', 'alex');
                INSERT INTO person_observations VALUES (1, 'alex', 'manual'), (2, 'alex', 'manual'), (3, 'alex', 'manual');
                INSERT INTO person_notes VALUES ('note', 'alex', 'Shared context', 4, 4);
                INSERT INTO relationship_templates VALUES ('founder-outreach', 1, '\(template)');
                INSERT INTO person_templates VALUES ('alex', 'founder-outreach', 1, 'evaluating');
                INSERT INTO person_template_milestones VALUES ('alex', 'tried-product', 0), ('alex', 'joined-slack', 1);
                """
            XCTAssertEqual(sqlite3_exec(oldDB, fixture, nil, nil, nil), SQLITE_OK)
        }
        func alerts(_ store: CaptureStore, _ workspace: String? = nil) throws -> [Int64] {
            try store.inbox(InboxQuery(scope: .person("alex"), workspaceID: workspace)).map(\.id)
        }
        let personal: String
        let startup: String
        do {
            let store = try CaptureStore(path: path)
            XCTAssertEqual(try store.people().map(\.id), ["alex", "sam"])
            XCTAssertEqual(try alerts(store), [3, 2, 1])
            personal = try store.createWorkspace(name: "Personal")
            startup = try store.createWorkspace(name: "Startup 1")
            XCTAssertThrowsError(try store.createWorkspace(name: " personal "))
            for _ in 1...2 {
                try store.setWorkspaceMembership(person: "alex", workspace: personal, isMember: true)
            }
            try store.setWorkspaceMembership(person: "alex", workspace: startup, isMember: true)
            XCTAssertEqual(try alerts(store, personal), [3, 2, 1])
            try store.setAlertWorkspace(1, to: personal)
            try store.setAlertWorkspace(2, to: startup)
            XCTAssertEqual(try alerts(store, personal), [3, 1])
            XCTAssertEqual(try alerts(store, startup), [3, 2])
            let routeSearch = InboxQuery(scope: .person("alex"), search: "Startup alert", workspaceID: personal)
            XCTAssertTrue(try store.inbox(routeSearch).isEmpty)
            let unassignedSearch = InboxQuery(scope: .person("alex"), search: "Unassigned alert", workspaceID: personal)
            XCTAssertEqual(try store.inbox(unassignedSearch).map(\.id), [3])
        }

        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.workspaces().map(\.name), ["Personal", "Startup 1"])
        XCTAssertEqual(try reopened.workspaceIDs(for: "alex"), [personal, startup])
        XCTAssertEqual(try reopened.people(in: personal).map(\.id), ["alex"])
        XCTAssertEqual(try reopened.people(in: startup).map(\.id), ["alex"])
        for _ in 1...2 {
            try reopened.setWorkspaceMembership(person: "alex", workspace: personal, isMember: false)
        }
        XCTAssertEqual(try reopened.people(in: personal).map(\.id), [])
        XCTAssertEqual(try alerts(reopened, personal), [])
        XCTAssertEqual(try alerts(reopened, startup), [3, 2])
        XCTAssertEqual(try reopened.inbox(InboxQuery(workspaceID: personal)).map(\.id), [1])
        XCTAssertEqual(try reopened.people().map(\.id), ["alex", "sam"])
        XCTAssertEqual(try reopened.identities(for: "alex").map(\.identifier), ["alex"])
        XCTAssertEqual(try reopened.personNotes(for: "alex").map(\.body), ["Shared context"])
        XCTAssertEqual(try reopened.templateAssignment(for: "alex")?.stageID, "evaluating")
        XCTAssertEqual(try reopened.templateAssignment(for: "alex")?.completedMilestones, ["joined-slack"])
        XCTAssertThrowsError(try reopened.createPerson(name: "Invalid", workspace: "unknown"))
        XCTAssertEqual(try reopened.people().map(\.id), ["alex", "sam"])
        let newPerson = try reopened.createPerson(name: "Taylor", workspace: personal)
        XCTAssertEqual(try reopened.people(in: personal).map(\.id), [newPerson])
        XCTAssertThrowsError(try reopened.setAlertWorkspace(1, to: "unknown"))
        XCTAssertEqual(try reopened.inbox(InboxQuery(workspaceID: personal)).map(\.id), [1])
        try reopened.setAlertWorkspace(1, to: startup)
        XCTAssertEqual(try alerts(reopened, startup), [3, 2, 1])
        try reopened.setAlertWorkspace(1, to: nil)
        XCTAssertEqual(try alerts(reopened, startup), [3, 2, 1])
        XCTAssertEqual(try alerts(reopened), [3, 2, 1])
    }
}
