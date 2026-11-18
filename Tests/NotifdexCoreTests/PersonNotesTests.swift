import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class PersonNotesTests: XCTestCase {
    func testVersionFourMigrationAndNoteLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path

        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            for resource in ["schema", "inbox-work", "filters", "person-matches"] {
                let sql = try CaptureStore.schema(named: resource)
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
            let fixture = """
                PRAGMA user_version = 4;
                INSERT INTO people VALUES ('first', 'Alex'), ('second', 'Alex');
                INSERT INTO identities VALUES ('x', 'first', 'X', 'alex');
                """
            XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        }

        let id: String
        do {
            let store = try CaptureStore(path: path)
            XCTAssertEqual(Set(try store.people().map(\.id)), ["first", "second"])
            XCTAssertEqual(try store.identities(for: "first").first?.identifier, "alex")
            XCTAssertTrue(try store.personNotes(for: "first").isEmpty)
            XCTAssertThrowsError(try store.addPersonNote(person: "first", body: "\n  ", at: 1))
            XCTAssertThrowsError(try store.addPersonNote(person: "missing", body: "Orphan", at: 1))
            id = try store.addPersonNote(person: "first", body: "First line\n第二行", at: 2)
            try store.addPersonNote(person: "first", body: "Another note", at: 3)
            try store.addPersonNote(person: "second", body: "Separate history", at: 4)
            XCTAssertThrowsError(try store.updatePersonNote(id, person: "second", body: "Wrong owner", at: 5))
            XCTAssertThrowsError(try store.deletePersonNote(id, person: "second"))
        }
        do {
            let store = try CaptureStore(path: path)
            let notes = try store.personNotes(for: "first")
            XCTAssertEqual(notes.map(\.body), ["Another note", "First line\n第二行"])
            XCTAssertEqual(try store.personNotes(for: "second").map(\.body), ["Separate history"])
            try store.updatePersonNote(id, person: "first", body: "Updated", at: 6)
            let edited = try XCTUnwrap(store.personNotes(for: "first").first { $0.id == id })
            XCTAssertEqual(edited.body, "Updated")
            XCTAssertEqual(edited.createdAt, 2)
            XCTAssertEqual(edited.updatedAt, 6)
            try store.deletePersonNote(id, person: "first")
        }
        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.personNotes(for: "first").map(\.body), ["Another note"])
        XCTAssertEqual(try reopened.personNotes(for: "second").map(\.body), ["Separate history"])
    }
}
