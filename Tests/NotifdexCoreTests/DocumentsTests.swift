import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class DocumentsTests: XCTestCase {
    func testUpgradeAndDocumentLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("capture.db").path
        let personal: String
        let person: String
        do {
            let store = try CaptureStore(path: path)
            person = try store.createPerson(name: "Reader")
            try store.addPersonNote(person: person, body: "Relationship context", at: 1)
            personal = try store.savePersonalNote(folderID: nil, title: "Note", body: "Private context", at: 2)
        }
        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            XCTAssertEqual(sqlite3_exec(db, "DROP TABLE documents; PRAGMA user_version = 10;", nil, nil, nil), SQLITE_OK)
        }
        let first: String
        let second: String
        do {
            let store = try CaptureStore(path: path)
            XCTAssertTrue(try store.documents().isEmpty)
            first = try store.saveDocument(title: " Guide ", body: "# Heading\nRéférence", at: 3)
            second = try store.saveDocument(title: "Checklist", body: "- Item", at: 4)
            XCTAssertEqual(try store.documents().map(\.id), [second, first])
            XCTAssertThrowsError(try store.saveDocument(first, title: "", body: "Invalid", at: 5))
            XCTAssertEqual(try store.document(first).title, "Guide")
            XCTAssertEqual(try store.document(first).body, "# Heading\nRéférence")
            XCTAssertThrowsError(try store.saveDocument(title: "Too big",
                                                        body: String(repeating: "x", count: LocalDocument.maximumBodyBytes + 1),
                                                        at: 5))
            XCTAssertThrowsError(try store.saveDocument("missing", title: "Title", body: "Text", at: 5))
            XCTAssertEqual(try store.saveDocument(first, title: "Revised", body: "Updated", at: 6), first)
        }
        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.documents().map(\.id), [first, second])
        XCTAssertEqual(try reopened.document(first).body, "Updated")
        try reopened.deleteDocument(first)
        XCTAssertThrowsError(try reopened.document(first))
        XCTAssertEqual(try reopened.documents().map(\.id), [second])
        XCTAssertEqual(try reopened.personalNotes().first?.id, personal)
        XCTAssertEqual(try reopened.personNotes(for: person).first?.body, "Relationship context")
    }
}
