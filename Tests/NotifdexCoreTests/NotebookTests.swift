import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class NotebookTests: XCTestCase {
    func testUpgradeFromVersionNineKeepsPeopleNotesAndAddsPrivateNotebook() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("capture.db").path

        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            for name in ["schema", "inbox-work", "filters", "person-matches", "person-notes",
                         "flags", "hide-rules", "relationship-templates", "workspaces"] {
                XCTAssertEqual(sqlite3_exec(db, try CaptureStore.schema(named: name), nil, nil, nil), SQLITE_OK)
            }
            let legacy = """
                PRAGMA user_version = 9;
                INSERT INTO people VALUES ('maya', 'Maya'), ('another', 'Maya');
                INSERT INTO person_notes VALUES ('old', 'maya', 'Legacy text', 1, 2);
                """
            XCTAssertEqual(sqlite3_exec(db, legacy, nil, nil, nil), SQLITE_OK)
        }

        let noteID: String
        do {
            let store = try CaptureStore(path: path)
            let legacy = try XCTUnwrap(store.personNotes(for: "maya").first)
            XCTAssertEqual(legacy.id, "old")
            XCTAssertEqual(legacy.title, "")
            XCTAssertEqual(legacy.body, "Legacy text")
            XCTAssertEqual(legacy.createdAt, 1)
            XCTAssertEqual(legacy.updatedAt, 2)
            XCTAssertTrue(try store.personNotes(for: "another").isEmpty)
            XCTAssertTrue(try store.personalNotes().isEmpty)

            try store.updatePersonNote(legacy.id, person: "maya", title: "Shared title", body: "Edit from Notes", at: 3)
            let readFromProfile = try XCTUnwrap(store.personNotes(for: "maya").first)
            XCTAssertEqual(readFromProfile.id, legacy.id)
            XCTAssertEqual(readFromProfile.title, "Shared title")
            XCTAssertEqual(readFromProfile.body, "Edit from Notes")
            try store.updatePersonNote(legacy.id, person: "maya", body: "Edit from profile", at: 4)
            XCTAssertEqual(try store.personNotes(for: "maya").first?.title, "Shared title")

            let ideas = try store.saveNoteFolder(name: " Ideas ")
            let work = try store.saveNoteFolder(name: "Work")
            XCTAssertThrowsError(try store.saveNoteFolder(name: "ideas"))
            try store.saveNoteFolder(work, name: "Drafts")
            XCTAssertEqual(try store.noteFolders().map(\.name), ["Drafts", "Ideas"])
            noteID = try store.savePersonalNote(folderID: ideas, title: "Plan", body: "Plain text", at: 5)
            XCTAssertThrowsError(try store.savePersonalNote(noteID, folderID: "absent", title: "", body: "Wrong", at: 6))
            XCTAssertEqual(try store.personalNotes().first?.folderID, ideas)
            try store.savePersonalNote(noteID, folderID: work, title: "Moved", body: "Plain text", at: 7)
            try store.deleteNoteFolder(work)
        }

        let reopened = try CaptureStore(path: path)
        let personal = try XCTUnwrap(reopened.personalNotes().first)
        XCTAssertEqual(personal.id, noteID)
        XCTAssertNil(personal.folderID)
        XCTAssertEqual(personal.title, "Moved")
        XCTAssertEqual(personal.createdAt, 5)
        XCTAssertEqual(personal.updatedAt, 7)
        XCTAssertEqual(try reopened.personNotes(for: "maya").first?.body, "Edit from profile")
        try reopened.deletePersonalNote(noteID)
        XCTAssertTrue(try reopened.personalNotes().isEmpty)
        XCTAssertEqual(try reopened.personNotes(for: "maya").first?.id, "old")
    }
}
