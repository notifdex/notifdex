import Foundation
import XCTest
@testable import NotifdexCore

final class StorageManagementTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifdexStorageMgmtTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeStore(named name: String = "capture") throws -> (CaptureStore, URL) {
        let url = tempDir.appendingPathComponent("\(name).db")
        let store = try CaptureStore(path: url.path)
        return (store, url)
    }

    func testStorageUsageReportCalculatesWalSidecarsMediaAndCategoryBreakdown() throws {
        let (store, dbURL) = try makeStore()
        let runID = try store.startRun(at: 1_700_000_000)

        let payload = String(repeating: "Notification payload text ", count: 120)
        try store.record(Observation(
            sourceID: "mac:notificationcenter", sourceEventID: "ev-1", capturedAt: 1_700_000_100,
            description: "Gmail, Alice, \(payload), from iPhone", title: "Alice", body: payload
        ), runID: runID)
        try store.record(Observation(
            sourceID: "mac:notificationcenter", sourceEventID: "ev-2", capturedAt: 1_700_500_000,
            description: "X, Bob, Hello world, from iPhone", title: "Bob", body: "Hello world"
        ), runID: runID)

        // Create a synthetic custom backdrop media file alongside the DB.
        let mediaURL = tempDir.appendingPathComponent("custom-backdrop.img")
        try Data(repeating: 0xAB, count: 4096).write(to: mediaURL)

        let report = try store.storageUsageReport(
            databaseURL: dbURL,
            mediaFileURLs: [mediaURL],
            at: 1_700_600_000
        )

        XCTAssertEqual(report.observationCount, 2)
        XCTAssertEqual(report.oldestObservationAt, 1_700_000_100)
        XCTAssertEqual(report.newestObservationAt, 1_700_500_000)
        XCTAssertEqual(report.calculatedAt, 1_700_600_000)
        XCTAssertEqual(report.attachmentsAndMediaBytes, 4096)
        XCTAssertGreaterThan(report.databaseFileBytes + report.walBytes, 0)
        XCTAssertGreaterThan(report.contentAndPayloadsBytes, 3000)
        XCTAssertGreaterThanOrEqual(report.recordsAndMetadataBytes, 0)
        XCTAssertGreaterThanOrEqual(report.indexesAndOverheadBytes, 0)
        XCTAssertEqual(
            report.totalBytes,
            report.databaseFileBytes + report.walBytes + report.shmBytes + report.auxiliaryDatabaseBytes + report.attachmentsAndMediaBytes
        )
        XCTAssertFalse(report.formattedTotalSize.isEmpty)
    }

    func testAgeCleanupReclaimsSpacePreservesProtectedAndUserDataAndMaintainsIntegrity() throws {
        let (store, dbURL) = try makeStore()
        let now: Double = 1_760_000_000
        let day: Double = 86_400
        let runID = try store.startRun(at: now - 400 * day)

        // Seed 60 large old disposable observations (120 days old) with read/hidden rows to exercise FK cleanup.
        let bigBody = String(repeating: "Archived alert body content for space reclamation check. ", count: 60)
        for i in 0..<60 {
            try store.record(Observation(
                sourceID: "mac:notificationcenter", sourceEventID: "old-\(i)",
                capturedAt: now - 120 * day + Double(i),
                description: "Gmail, Digest \(i), \(bigBody), from iPhone",
                title: "Digest \(i)", body: bigBody
            ), runID: runID)
        }
        // Mark some old disposable alerts as read or individually hidden so FK tables are populated.
        let allOld = try store.inbox(InboxQuery(limit: 100))
        if let first = allOld.first {
            try store.setRead(first.id, read: true)
        }
        if allOld.count > 1 {
            try store.hideAlert(allOld[1].id, at: now - 100 * day)
        }

        // Seed 4 old PROTECTED observations (120 days old): saved, flagged, active follow-up, person-linked.
        let protectedCases = ["SavedAlert", "FlaggedAlert", "FollowUpAlert", "PersonLinkedAlert"]
        for (idx, name) in protectedCases.enumerated() {
            try store.record(Observation(
                sourceID: "mac:notificationcenter", sourceEventID: "prot-\(idx)",
                capturedAt: now - 120 * day - Double(idx + 1),
                description: "X, \(name), Keep me safe, from iPhone",
                title: name, body: "Keep me safe"
            ), runID: runID)
        }
        let recentEntryTime = now - 5 * day
        try store.record(Observation(
            sourceID: "mac:notificationcenter", sourceEventID: "recent-1",
            capturedAt: recentEntryTime,
            description: "X, RecentFriend, Fresh message, from iPhone",
            title: "RecentFriend", body: "Fresh message"
        ), runID: runID)

        let rows = try store.inbox(InboxQuery(limit: 200))
        let savedID = try XCTUnwrap(rows.first(where: { $0.title == "SavedAlert" })?.id)
        let flaggedID = try XCTUnwrap(rows.first(where: { $0.title == "FlaggedAlert" })?.id)
        let followUpID = try XCTUnwrap(rows.first(where: { $0.title == "FollowUpAlert" })?.id)
        let linkedID = try XCTUnwrap(rows.first(where: { $0.title == "PersonLinkedAlert" })?.id)

        try store.setSaved(savedID, saved: true)
        try store.setFlag(flaggedID, flagged: true)
        try store.schedule(followUpID, dueAt: now + 3 * day)
        let wsID = try store.createWorkspace(name: "VIPs")
        let personID = try store.createPerson(name: "Dana Kim", linking: linkedID, workspace: wsID)
        _ = try store.addPersonNote(person: personID, title: "Bio", body: "Key contact", at: now - 10 * day)
        _ = try store.savePersonalNote(folderID: nil, title: "Scratchpad", body: "Important note", at: now - 10 * day)
        _ = try store.addHideRule(InboxRuleMatch(app: "Discord", field: .app, text: "Discord"), at: now - 10 * day)

        // Preview 90-day cleanup before confirming.
        let preview = try store.previewStorageCleanup(
            period: .olderThan90Days,
            databaseURL: dbURL,
            now: now
        )
        XCTAssertEqual(preview.removableObservationCount, 60)
        XCTAssertEqual(preview.preservedObservationCount, 4)
        XCTAssertGreaterThan(preview.estimatedReclaimableBytes, 0)
        XCTAssertEqual(preview.preservedPeopleCount, 1)
        XCTAssertEqual(preview.preservedNotesCount, 2)
        XCTAssertEqual(preview.preservedWorkspacesCount, 1)
        XCTAssertEqual(preview.preservedHideRulesCount, 1)

        // Execute cleanup + VACUUM + integrity check.
        let result = try store.performStorageCleanup(
            period: .olderThan90Days,
            databaseURL: dbURL,
            now: now
        )
        XCTAssertEqual(result.removedObservations, 60)
        XCTAssertEqual(result.preservedObservations, 4)
        XCTAssertTrue(result.vacuumPerformed)
        XCTAssertTrue(result.integrityOK)
        XCTAssertLessThan(result.bytesAfter, result.bytesBefore, "VACUUM + WAL truncate must actually reclaim disk space.")
        XCTAssertGreaterThan(result.reclaimedBytes, 0)

        // Verify remaining alerts = 4 old protected + 1 recent = 5.
        XCTAssertEqual(try store.observationCount(), 5)
        // Verify ALL user-created records remain intact.
        XCTAssertEqual(try store.people().map(\.name), ["Dana Kim"])
        XCTAssertEqual(try store.personNotes(for: personID).count, 1)
        XCTAssertEqual(try store.personalNotes().count, 1)
        XCTAssertEqual(try store.workspaces().map(\.name), ["VIPs"])
        XCTAssertEqual(try store.inboxFilters().count, 1)

        // Verify updated storage usage reflects reclaimed size and new count.
        let afterReport = try store.storageUsageReport(databaseURL: dbURL, at: now + 5)
        XCTAssertEqual(afterReport.observationCount, 5)
        XCTAssertEqual(afterReport.totalBytes, result.bytesAfter)
    }

    func testClearAllHistoryRemovesAllAlertsButPreservesPeopleNotesWorkspacesAndRules() throws {
        let (store, dbURL) = try makeStore(named: "clear-all")
        let now: Double = 1_760_000_000
        let runID = try store.startRun(at: now - 100)
        try store.record(Observation(
            sourceID: "mac:notificationcenter", sourceEventID: "ev-1", capturedAt: now - 50,
            description: "X, Sam, Ping, from iPhone", title: "Sam", body: "Ping"
        ), runID: runID)
        let entry = try XCTUnwrap(try store.inbox(InboxQuery()).first)
        try store.setSaved(entry.id, saved: true)
        try store.setFlag(entry.id, flagged: true)
        let wsID = try store.createWorkspace(name: "Core")
        let personID = try store.createPerson(name: "Sam", linking: entry.id, workspace: wsID)
        _ = try store.addPersonNote(person: personID, title: "Note", body: "Keep forever", at: now - 20)
        _ = try store.savePersonalNote(folderID: nil, title: "Journal", body: "Do not delete", at: now - 20)
        _ = try store.addHideRule(InboxRuleMatch(app: "Gmail", field: .title, text: "Spam"), at: now - 20)

        let result = try store.performStorageCleanup(period: .allHistory, databaseURL: dbURL, now: now)
        XCTAssertEqual(result.removedObservations, 1)
        XCTAssertTrue(result.integrityOK)
        XCTAssertEqual(try store.observationCount(), 0)
        XCTAssertEqual(try store.people().count, 1)
        XCTAssertEqual(try store.personNotes(for: personID).count, 1)
        XCTAssertEqual(try store.personalNotes().count, 1)
        XCTAssertEqual(try store.workspaces().count, 1)
        XCTAssertEqual(try store.inboxFilters().count, 1)
    }

    func testLocalCleanupWatermarkPreventsCloudSyncFromResurrectingPrunedOldAlerts() async throws {
        let (iosStore, iosURL) = try makeStore(named: "ios-cleanup")
        let (macStore, _) = try makeStore(named: "mac-peer")
        let transport = InMemorySyncTransport()

        let now: Double = 1_760_000_000
        let day: Double = 86_400
        try iosStore.pairDevice(deviceID: "ios-1", displayName: "iPhone", platform: .iphone, at: now - 200 * day)
        try macStore.pairDevice(deviceID: "mac-1", displayName: "Mac", platform: .mac, at: now - 200 * day)

        // Mac holds an old 120-day alert and a fresh 1-day alert.
        let runID = try macStore.startRun(at: now - 130 * day)
        try macStore.record(Observation(
            sourceID: "mac-1:notificationcenter", sourceEventID: "old-120d", capturedAt: now - 120 * day,
            description: "Gmail, OldPromo, Expired deal, from iPhone", title: "OldPromo", body: "Expired deal"
        ), runID: runID)
        try macStore.record(Observation(
            sourceID: "mac-1:notificationcenter", sourceEventID: "fresh-1d", capturedAt: now - 1 * day,
            description: "X, Friend, See you tonight, from iPhone", title: "Friend", body: "See you tonight"
        ), runID: runID)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: "mac-1", at: now - 10)
        _ = try await iosCoord.syncNow(localDeviceID: "ios-1", at: now - 5)
        XCTAssertEqual(try iosStore.observationCount(), 2)

        // iPhone cleans up alerts older than 90 days to reclaim local storage.
        let cleanup = try iosStore.performStorageCleanup(period: .olderThan90Days, databaseURL: iosURL, now: now)
        XCTAssertEqual(cleanup.removedObservations, 1)
        XCTAssertEqual(try iosStore.observationCount(), 1)

        // Mac captures another fresh alert and pushes its full snapshot; iPhone syncs again.
        try macStore.record(Observation(
            sourceID: "mac-1:notificationcenter", sourceEventID: "brand-new", capturedAt: now + 10,
            description: "X, Friend, On my way, from iPhone", title: "Friend", body: "On my way"
        ), runID: runID)
        _ = try await macCoord.syncNow(localDeviceID: "mac-1", at: now + 15)
        _ = try await iosCoord.syncNow(localDeviceID: "ios-1", at: now + 20)

        // iPhone receives the new alert, does NOT resurrect the pruned 120-day alert,
        // and Mac's full 3-alert history remains untouched!
        XCTAssertEqual(try iosStore.observationCount(), 2)
        XCTAssertFalse(try iosStore.inbox(InboxQuery()).contains(where: { $0.title == "OldPromo" }))
        XCTAssertEqual(try macStore.observationCount(), 3)
    }

    func testStandaloneCompactDatabasePreservesDataAndIntegrity() throws {
        let (store, dbURL) = try makeStore(named: "compact")
        let runID = try store.startRun(at: 100)
        try store.record(Observation(
            sourceID: "mac:notificationcenter", sourceEventID: "ev-1", capturedAt: 105,
            description: "X, Alex, Hello, from iPhone", title: "Alex", body: "Hello"
        ), runID: runID)

        let result = try store.compactDatabase(databaseURL: dbURL, at: 200)
        XCTAssertTrue(result.vacuumPerformed)
        XCTAssertTrue(result.integrityOK)
        XCTAssertEqual(try store.observationCount(), 1)
    }
}
