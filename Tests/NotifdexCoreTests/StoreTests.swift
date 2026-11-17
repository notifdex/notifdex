import Foundation
import XCTest
@testable import NotifdexCore

final class StoreTests: XCTestCase {
    var directory: URL!
    var path: String { directory.appendingPathComponent("test.db").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func observation(id: String = "banner-1", body: String = "Hello") -> Observation {
        Observation(sourceID: "device-1:notificationcenter", sourceEventID: id,
                    capturedAt: 10, description: "X, Alex, \(body), from iPhone",
                    title: "Alex", body: body)
    }

    func testRetryAndRestartProduceOneRow() throws {
        var store: CaptureStore? = try CaptureStore(path: path)
        let run = try store!.startRun(at: 1)
        XCTAssertTrue(try store!.record(observation(), runID: run))
        XCTAssertFalse(try store!.record(observation(), runID: run))
        store = nil
        let reopened = try CaptureStore(path: path)
        let nextRun = try reopened.startRun(at: 20)
        XCTAssertFalse(try reopened.record(observation(), runID: nextRun))
        XCTAssertEqual(try reopened.observationCount(), 1)
        XCTAssertEqual(try reopened.gapCount(reason: "unclean_exit"), 1)
    }

    func testIdenticalMessagesWithDifferentIDsSurvive() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        _ = try store.record(observation(), runID: run)
        _ = try store.record(observation(id: "banner-2"), runID: run)
        XCTAssertEqual(try store.observationCount(), 2)
    }

    func testChangedPreviewAndDifferentSourceArePreserved() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        _ = try store.record(observation(), runID: run)
        _ = try store.record(observation(body: "Changed"), runID: run)
        var other = observation()
        other.sourceID = "device-2:notificationcenter"
        _ = try store.record(other, runID: run)
        XCTAssertEqual(try store.observationCount(), 3)
    }

    func testUnknownRunFailsWithoutDroppingObservationSilently() throws {
        let store = try CaptureStore(path: path)
        XCTAssertThrowsError(try store.record(observation(), runID: "missing"))
        XCTAssertEqual(try store.observationCount(), 0)
    }

    func testEmptySourceIDFails() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        var value = observation()
        value.sourceEventID = ""
        XCTAssertThrowsError(try store.record(value, runID: run))
    }

    func testPauseGapIsIdempotentAndRecoveryRetainsHistory() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        try store.openGap(runID: run, reason: "permission", at: 2)
        try store.openGap(runID: run, reason: "permission", at: 3)
        XCTAssertEqual(try store.gapCount(reason: "permission"), 1)
        try store.recover(runID: run, at: 4)
        XCTAssertEqual(try store.gapCount(reason: "permission"), 1)
        XCTAssertEqual(try store.openGapCount(), 0)
    }

    func testGracefulStopStillRecordsUnobservedIntervalOnRestart() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        try store.finishRun(runID: run, at: 2)
        _ = try store.startRun(at: 4)
        XCTAssertEqual(try store.gapCount(reason: "collector_stopped"), 1)
    }

    func testUnicodeQuotesAndCommaParsing() throws {
        let value = Observation(sourceID: "d", sourceEventID: "1", capturedAt: 10,
                                description: "X, Alex, Jr., Hi, '世界' 👋, from iPhone",
                                title: "Alex, Jr.", body: "Hi, '世界' 👋")
        XCTAssertEqual(value.appLabel, "X")
        XCTAssertEqual(value.origin, .iphone)
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        XCTAssertTrue(try store.record(value, runID: run))
    }

    func testUnrecognizedDescriptionDoesNotInventAppOrOrigin() {
        let value = Observation(sourceID: "d", sourceEventID: "1", capturedAt: 10,
                                description: "Unrecognized description", title: "Alex", body: "Hello")
        XCTAssertNil(value.appLabel)
        XCTAssertEqual(value.origin, .unknown)
    }

    func testEmbeddedNULDoesNotCollapseDistinctRenderings() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        _ = try store.record(observation(body: "Hi\0one"), runID: run)
        _ = try store.record(observation(body: "Hi\0two"), runID: run)
        XCTAssertEqual(try store.observationCount(), 2)
    }

    func testCorruptDatabaseFailsStartup() throws {
        try Data("This is not SQLite".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try CaptureStore(path: path))
    }
}
