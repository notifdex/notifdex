import Foundation
import XCTest
@testable import NotifdexCore

final class InboxFilterTests: XCTestCase {
    func testSingleAndSubjectHideCanBeUndoneIndependently() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("capture.db").path
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        func capture(_ id: String, app: String = "Gmail", subject: String = "Daily digest",
                     sender: String = "Bot") throws {
            try store.record(Observation(sourceID: "phone", sourceEventID: id, capturedAt: 2,
                                         description: "\(app), \(sender), \(subject), from iPhone",
                                         title: sender, body: subject), runID: run)
        }

        try capture("first")
        try capture("same text different app", app: "X")
        try capture("different subject", subject: "Daily digest update")
        let first = try XCTUnwrap(store.inbox(InboxQuery()).last)
        let id = first.id
        XCTAssertEqual(first.subject, "Daily digest")
        XCTAssertFalse(first.isRead)
        try store.setSaved(id, saved: true)
        try store.schedule(id, dueAt: 3)
        try store.setRead(id, read: true)
        try store.hideAlert(id)
        XCTAssertEqual(try store.inbox(InboxQuery()).count, 2)
        XCTAssertEqual(try store.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.id), [id])

        try store.hideSubject(app: first.app, subject: first.subject)
        try store.hideSubject(app: first.app, subject: first.subject)
        try capture("future", sender: "Another sender")
        let reopened = try CaptureStore(path: path)
        XCTAssertEqual(try reopened.inboxFilters().count, 1)
        XCTAssertEqual(try reopened.inbox(InboxQuery()).map(\.body), ["Daily digest update", "Daily digest"])
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .hidden(app: "Gmail"))).count, 2)
        let saved = try XCTUnwrap(reopened.inbox(InboxQuery(scope: .inbox(app: nil, saved: true))).first)
        XCTAssertEqual(saved.id, id)
        XCTAssertTrue(saved.isRead)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .followUps)).first?.id, id)

        try reopened.restoreSubject(app: first.app, subject: first.subject)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.id), [id])
        try reopened.restoreAlert(id)
        try reopened.setRead(id, read: false)
        XCTAssertTrue(try reopened.inbox(InboxQuery(scope: .hidden(app: nil))).isEmpty)
        let restored = try XCTUnwrap(reopened.inbox(InboxQuery()).first { $0.id == id })
        XCTAssertFalse(restored.isRead)
        XCTAssertFalse(restored.done)
        XCTAssertEqual(try reopened.observationCount(), 4)
    }

    func testAppLinksUseKnownDestinations() {
        XCTAssertEqual(InboxDestination.webURL(for: "X")?.host, "x.com")
        XCTAssertEqual(InboxDestination.webURL(for: "Gmail")?.host, "mail.google.com")
        XCTAssertEqual(InboxDestination.nativeURL(for: "WhatsApp")?.scheme, "whatsapp")
        XCTAssertNil(InboxDestination.webURL(for: "https://example.com"))
    }
}
