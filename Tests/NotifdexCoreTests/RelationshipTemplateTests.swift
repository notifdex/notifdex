import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class RelationshipTemplateTests: XCTestCase {
    func testInstallApplyAndSetRetriesPreservePinnedProgress() throws {
        let store = try CaptureStore(path: ":memory:")
        let person = try store.createPerson(name: "Alex")
        let definition = try RelationshipTemplate.bundledFounderOutreach()
        let v2 = try template(version: 2, name: "Outreach v2")
        XCTAssertEqual(try store.installTemplate(definition), definition)
        XCTAssertEqual(try store.installTemplate(definition), definition)
        XCTAssertThrowsError(try store.installTemplate(template(version: 1, name: "Conflict"))) {
            XCTAssertEqual($0 as? RelationshipTemplateError, .versionConflict)
        }
        XCTAssertEqual(try store.applyTemplate(definition, to: person).stageID, "contacted")
        for _ in 1...2 {
            try store.setTemplateStage("evaluating", for: person)
            try store.setTemplateMilestone("joined-slack", completed: true, for: person)
        }
        let progress = try XCTUnwrap(store.templateAssignment(for: person))
        XCTAssertEqual(progress.stageID, "evaluating")
        XCTAssertEqual(progress.completedMilestones, ["joined-slack"])
        XCTAssertEqual(try store.applyTemplate(definition, to: person), progress)
        XCTAssertEqual(try store.installTemplate(v2), v2)
        XCTAssertThrowsError(try store.applyTemplate(v2, to: person)) {
            XCTAssertEqual($0 as? RelationshipTemplateError, .assignmentConflict)
        }
        XCTAssertThrowsError(try store.setTemplateStage("unknown", for: person))
        XCTAssertThrowsError(try store.setTemplateMilestone("unknown", completed: true, for: person))
        XCTAssertEqual(try store.templateAssignment(for: person), progress)
        for _ in 1...2 {
            try store.setTemplateMilestone("joined-slack", completed: false, for: person)
        }
        XCTAssertEqual(try store.templateAssignment(for: person)?.completedMilestones, [])
        XCTAssertEqual(try store.templateAssignment(for: person)?.stageID, "evaluating")

        let anotherPerson = try store.createPerson(name: "Sam")
        XCTAssertEqual(try store.applyTemplate(v2, to: anotherPerson).definition, v2)
    }

    func testRemovingTemplateClearsOnlyThatPersonsProgress() throws {
        let store = try CaptureStore(path: ":memory:")
        let alex = try store.createPerson(name: "Alex")
        let sam = try store.createPerson(name: "Sam")
        let workspace = try store.createWorkspace(name: "Startup")
        try store.setWorkspaceMembership(person: alex, workspace: workspace, isMember: true)
        try store.addPersonNote(person: alex, body: "Keep this context", at: 1)
        let definition = try store.installTemplate(RelationshipTemplate.bundledFounderOutreach())
        let newer = try store.installTemplate(template(version: 2, name: "Outreach v2"))
        try store.applyTemplate(definition, to: alex)
        try store.applyTemplate(definition, to: sam)
        try store.setTemplateStage("evaluating", for: alex)
        try store.setTemplateMilestone("joined-slack", completed: true, for: alex)
        try store.setTemplateMilestone("tried-product", completed: true, for: sam)

        try store.removeTemplate(newer, from: alex)
        XCTAssertEqual(try store.templateAssignment(for: alex)?.stageID, "evaluating")
        for _ in 1...2 { try store.removeTemplate(definition, from: alex) }
        XCTAssertNil(try store.templateAssignment(for: alex))
        XCTAssertEqual(try store.personNotes(for: alex).map(\.body), ["Keep this context"])
        XCTAssertEqual(try store.workspaceIDs(for: alex), [workspace])
        XCTAssertEqual(try store.templateAssignment(for: sam)?.completedMilestones, ["tried-product"])

        let reapplied = try store.applyTemplate(definition, to: alex)
        XCTAssertEqual(reapplied.stageID, "contacted")
        XCTAssertTrue(reapplied.completedMilestones.isEmpty)
    }

    func testDefinitionValidation() throws {
        XCTAssertThrowsError(try RelationshipTemplate.decode(Data("""
            {"id":"outreach","version":1,"name":"Outreach",
             "stages":[{"id":"initial","name":"Open"},{"id":"initial","name":"Duplicate"}],
             "milestones":[]}
            """.utf8)))
        XCTAssertThrowsError(try RelationshipTemplate.decode(Data("""
            {"id":"outreach","version":1,"name":"Outreach","stages":[],"milestones":[]}
            """.utf8)))
    }

    func testVersionSevenMigrationAndAssignmentRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path
        let settingsStore = AppSettingsStore(url: directory.appendingPathComponent("settings.json"))
        var settings = CaptureSettings(sourceID: "synthetic")
        settings.paused = true
        settings.automaticRecovery = false
        try settings.addCustomApp(label: "Test app")
        try settingsStore.save(settings)

        for resource in ["schema", "inbox-work", "filters", "person-matches", "person-notes", "flags", "hide-rules"] {
            try sql(CaptureStore.schema(named: resource), at: path)
        }
        try sql("""
            PRAGMA user_version = 7;
            INSERT INTO capture_runs VALUES ('run', 1, 2, 2);
            INSERT INTO observations VALUES (1, 'synthetic', 'event', 'run', 2, 'iphone',
                'Gmail', 'Alex', '', 'Digest', '', 1);
            INSERT INTO people VALUES ('alex', 'Alex');
            INSERT INTO person_observations VALUES (1, 'alex', 'manual');
            INSERT INTO person_notes VALUES ('note', 'alex', 'Test context', 2, 2);
            INSERT INTO inbox_filters VALUES (9, 'Gmail', 'body', 'Digest');
            INSERT INTO observation_work VALUES (1, 1, 123, 0);
            """, at: path)

        let definition = try RelationshipTemplate.bundledFounderOutreach()
        do {
            let store = try CaptureStore(path: path)
            XCTAssertEqual(try store.observationCount(), 1)
            XCTAssertEqual(try store.people().map(\.id), ["alex"])
            XCTAssertEqual(try store.personNotes(for: "alex").map(\.body), ["Test context"])
            XCTAssertEqual(try store.inboxFilters().map(\.id), [9])
            XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.id), [1])
            let entry = try XCTUnwrap(store.inbox(InboxQuery(scope: .followUps)).first)
            XCTAssertEqual(entry.personID, "alex")
            XCTAssertEqual(entry.dueAt, 123)
            XCTAssertTrue(entry.saved)
            XCTAssertEqual(try settingsStore.loadOrCreate(sourceID: "ignored"), settings)
            try store.installTemplate(definition)
            // Abort the second milestone insert, after the assignment and first milestone exist.
            try sql("""
                CREATE TRIGGER fail_second_milestone BEFORE INSERT ON person_template_milestones
                WHEN NEW.milestone_id = 'joined-slack'
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
                """, at: path)
            XCTAssertThrowsError(try store.applyTemplate(definition, to: "alex"))
        }

        let reopened = try CaptureStore(path: path)
        XCTAssertNil(try reopened.templateAssignment(for: "alex"))
        try sql("DROP TRIGGER fail_second_milestone", at: path)
        XCTAssertEqual(try reopened.applyTemplate(definition, to: "alex").stageID, "contacted")
        try reopened.setTemplateMilestone("tried-product", completed: true, for: "alex")
        let persisted = try CaptureStore(path: path)
        XCTAssertEqual(try persisted.templateAssignment(for: "alex")?.completedMilestones, ["tried-product"])
    }

    private func template(version: Int, name: String) throws -> RelationshipTemplate {
        try RelationshipTemplate.decode(Data("""
            {"id":"founder-outreach","version":\(version),"name":"\(name)",
             "stages":[{"id":"introduced","name":"Introduced"}],"milestones":[]}
            """.utf8))
    }

    private func sql(_ statement: String, at path: String) throws {
        var db: OpaquePointer?
        let opened = sqlite3_open(path, &db)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK, sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(description: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Open failed")
        }
    }
}
