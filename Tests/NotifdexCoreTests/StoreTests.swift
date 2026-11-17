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
        XCTAssertEqual(try reopened.openGapCount(), 1, "Only the new startup scan remains active")
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

    func testRecoverySnapshotBackfillsMissedAlertsAndReportsDuplicates() throws {
        var store: CaptureStore? = try CaptureStore(path: path)
        let firstRun = try store!.startRun(at: 1)
        _ = try store!.record(observation(), runID: firstRun)
        try store!.finishRun(runID: firstRun, at: 12)
        store = nil

        let restarted = try CaptureStore(path: path)
        let run = try restarted.startRun(at: 20)
        let snapshot = [observation(), observation(id: "missed-while-stopped")]
        let recovered = try restarted.recordBatch(snapshot, runID: run, at: 21)
        XCTAssertEqual(recovered.observed, 2)
        XCTAssertEqual(recovered.inserted, 1)
        XCTAssertEqual(recovered.duplicates, 1)

        let replay = try restarted.recordBatch(snapshot, runID: run, at: 22)
        XCTAssertEqual(replay.inserted, 0)
        XCTAssertEqual(replay.duplicates, 2)
        XCTAssertEqual(try restarted.observationCount(), 2)
    }

    func testRecoveryBatchRollsBackIfOneObservationIsInvalid() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        let values = [observation(), observation(id: "")]
        XCTAssertThrowsError(try store.recordBatch(values, runID: run, at: 10))
        XCTAssertEqual(try store.observationCount(), 0)
        let retry = try store.recordBatch([observation()], runID: run, at: 11)
        XCTAssertEqual(retry.inserted, 1)
    }

    func testEmptyRecoverySnapshotReportsZeroObserved() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        let result = try store.recordBatch([], runID: run, at: 10)
        XCTAssertEqual(result.observed, 0)
        XCTAssertEqual(result.inserted, 0)
        XCTAssertEqual(result.duplicates, 0)
        XCTAssertEqual(try store.openGapCount(), 1, "An empty scan alone does not close a gap")
    }

    func testAppCanReadRecentRowsAndAdoptExistingSource() throws {
        let store = try CaptureStore(path: path)
        let run = try store.startRun(at: 1)
        _ = try store.record(observation(body: "世界\0hello"), runID: run)
        let rows = try store.recentObservations(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].body, "世界\0hello")
        XCTAssertEqual(try store.sourceIDs(), ["device-1:notificationcenter"])
        let summaries = try store.appSummaries()
        XCTAssertEqual(summaries.first?.appLabel, "X")
        XCTAssertEqual(summaries.first?.count, 1)
    }
}
