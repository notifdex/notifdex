import Foundation
import XCTest
@testable import NotifdexCore

final class PersonMatchTests: XCTestCase {
    func testRememberMatchBackfillsAndPreservesExplicitChoices() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("capture.db").path
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        func capture(_ tag: String, app: String = "X", title: String = "Alex") throws -> Int64 {
            try store.record(Observation(sourceID: "phone", sourceEventID: tag, capturedAt: 2,
                                         description: "\(app), \(title), \(tag), from iPhone",
                                         title: title, body: tag), runID: run)
            return try XCTUnwrap(store.inbox(InboxQuery(search: tag)).first?.id)
        }

        let older = try capture("older-fixture")
        let anchor = try capture("anchor-fixture")
        let blocked = try capture("blocked-fixture")
        let otherApp = try capture("other-app", app: "Gmail")
        let engagement = try capture("engagement-one", title: "Liked by Alex")
        let alex = try store.createPerson(name: "Alex", linking: anchor)
        let anotherAlex = try store.createPerson(name: "Alex")
        try store.link(blocked, to: nil)
        let preview = try store.previewPersonMatch(for: anchor)
        XCTAssertEqual(preview.existingCount, 1)
        try store.confirmPersonMatch(preview, includeExisting: true)
        XCTAssertThrowsError(try store.confirmPersonMatch(preview, includeExisting: true))
        let future = try capture("future-fixture", app: "Twitter")

        let reopened = try CaptureStore(path: path)
        let matches = try reopened.inbox(InboxQuery(scope: .person(alex)))
        XCTAssertEqual(matches.map(\.id), [future, anchor, older])
        XCTAssertNotNil(matches[0].personRuleID)
        XCTAssertNil(matches[1].personRuleID)
        XCTAssertFalse(matches.contains { [blocked, otherApp, engagement].contains($0.id) })

        // A manual correction pauses ambiguous matches across this key.
        try reopened.link(older, to: anotherAlex)
        let rule = try XCTUnwrap(reopened.personMatchRules(for: alex).first)
        XCTAssertTrue(rule.hasConflict)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(alex))).map(\.id), [anchor])
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(anotherAlex))).map(\.id), [older])

        try reopened.link(older, to: nil)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(alex))).map(\.id), [future, anchor])
        try reopened.removePersonMatchRule(rule.id)
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(alex))).map(\.id), [anchor])
        try reopened.link(engagement, to: anotherAlex)
        let engagementPreview = try reopened.previewPersonMatch(for: engagement)
        XCTAssertEqual(engagementPreview.title, "Liked by Alex")
        let oldEngagement = try capture("engagement-old", title: "Liked by Alex")
        try reopened.confirmPersonMatch(engagementPreview, includeExisting: false)
        let newEngagement = try capture("engagement-new", title: "Liked by Alex")
        XCTAssertEqual(try reopened.inbox(InboxQuery(scope: .person(anotherAlex))).map(\.id),
                       [newEngagement, engagement])
        XCTAssertFalse(try reopened.inbox(InboxQuery(scope: .person(anotherAlex))).contains { $0.id == oldEngagement })
        let newer = try reopened.previewPersonMatch(for: anchor)
        XCTAssertEqual(newer.existingCount, 1) // Prior explicit unlinks stay excluded across rule recreation.
    }
}
