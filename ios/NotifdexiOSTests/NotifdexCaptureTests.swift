import NotifdexCore
import XCTest
@testable import NotifdexiOS

final class NotifdexCaptureTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifdexiOSTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("ios-capture.db")
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Normalization & Missing Fields

    func testNormalizerTrimsWhitespaceAndEdgeDirectionMarks() {
        let payload = IncomingNotificationPayload(
            app: "\u{200E} WhatsApp \u{200F}",
            title: "  Alex Chen  ",
            subtitle: "\n  ",
            body: "  Are we still on for 3pm? \n",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_000)
        )

        let normalized = CaptureNormalizer.normalize(payload)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.appLabel, "WhatsApp")
        XCTAssertEqual(normalized?.title, "Alex Chen")
        XCTAssertEqual(normalized?.subtitle, "")
        XCTAssertEqual(normalized?.body, "Are we still on for 3pm?")
        XCTAssertEqual(normalized?.origin, .iphone)
        XCTAssertEqual(normalized?.channel, .iosShortcuts)
    }

    func testNormalizerHandlesMissingOptionalFieldsSafely() {
        // Matches confirmed iOS 27 X automation output: Subtitle is empty/nil.
        let payload = IncomingNotificationPayload(
            app: "X",
            title: "Notifidex",
            subtitle: nil,
            body: "test123",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_010)
        )

        let normalized = CaptureNormalizer.normalize(payload)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.appLabel, "X")
        XCTAssertEqual(normalized?.title, "Notifidex")
        XCTAssertEqual(normalized?.subtitle, "")
        XCTAssertEqual(normalized?.body, "test123")
        XCTAssertFalse(normalized?.dedupKey.isEmpty ?? true)
    }

    func testNormalizerRejectsBlankAppLabel() {
        let payload = IncomingNotificationPayload(
            app: " \u{200E}\n ",
            title: "Hello",
            subtitle: nil,
            body: "World",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_020)
        )
        XCTAssertNil(CaptureNormalizer.normalize(payload))
    }

    func testNormalizerHandlesAppOnlyNotificationWithoutBodyOrTitle() {
        // Redacted lock-screen alerts may expose only the App name.
        let payload = IncomingNotificationPayload(
            app: "WeChat",
            title: nil,
            subtitle: nil,
            body: nil,
            receivedAt: Date(timeIntervalSince1970: 1_764_100_030)
        )
        let normalized = CaptureNormalizer.normalize(payload)
        XCTAssertNotNil(normalized)
        XCTAssertEqual(normalized?.appLabel, "WeChat")
        XCTAssertEqual(normalized?.title, "")
        XCTAssertEqual(normalized?.subtitle, "")
        XCTAssertEqual(normalized?.body, "")
    }

    // MARK: - Deduplication & Timestamps

    func testDedupKeyIsDeterministicWithinSameBucketAndDistinctAcrossBuckets() {
        let t1: Double = 1_764_100_020
        let t2: Double = 1_764_100_055 // same 60s bucket as t1
        let t3: Double = 1_764_100_120 // later 60s bucket

        let k1 = CaptureNormalizer.makeDedupKey(
            appLabel: "X", title: "Notifidex", subtitle: "", body: "test123", capturedAt: t1
        )
        let k2 = CaptureNormalizer.makeDedupKey(
            appLabel: "X", title: "Notifidex", subtitle: "", body: "test123", capturedAt: t2
        )
        let k3 = CaptureNormalizer.makeDedupKey(
            appLabel: "X", title: "Notifidex", subtitle: "", body: "test123", capturedAt: t3
        )

        XCTAssertFalse(k1.isEmpty)
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
    }

    func testDedupKeyDistinguishesDifferentAppsWithSameContent() {
        let ts: Double = 1_764_100_020
        let kX = CaptureNormalizer.makeDedupKey(
            appLabel: "X", title: "Sam", subtitle: "", body: "Ping", capturedAt: ts
        )
        let kGmail = CaptureNormalizer.makeDedupKey(
            appLabel: "Gmail", title: "Sam", subtitle: "", body: "Ping", capturedAt: ts
        )
        XCTAssertNotEqual(kX, kGmail)
    }

    // MARK: - Durable SQLite Persistence & Reopen

    func testSQLitePersistenceSurvivesStoreReopenAndPreservesOrdering() throws {
        let store1 = try NotificationStore(databaseURL: dbURL)
        let settings = try store1.loadOrCreateSettings(defaultDeviceID: "iphone-17-test")
        XCTAssertEqual(settings.deviceID, "iphone-17-test")
        XCTAssertEqual(settings.sourceID, "iphone-17-test:ios_shortcuts")

        let first = try XCTUnwrap(CaptureNormalizer.normalize(IncomingNotificationPayload(
            app: "Gmail",
            title: "Receipt",
            subtitle: "billing@example.com",
            body: "Order #1042 confirmed",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_000)
        )))
        let second = try XCTUnwrap(CaptureNormalizer.normalize(IncomingNotificationPayload(
            app: "X",
            title: "Notifidex",
            subtitle: nil,
            body: "test123",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_200)
        )))

        let r1 = try store1.insertNotification(first, sourceID: settings.sourceID, deviceID: settings.deviceID)
        let r2 = try store1.insertNotification(second, sourceID: settings.sourceID, deviceID: settings.deviceID)
        XCTAssertTrue(r1.inserted)
        XCTAssertTrue(r2.inserted)

        // Reopen database from disk to verify durability.
        let store2 = try NotificationStore(databaseURL: dbURL)
        let reopenedSettings = try store2.loadOrCreateSettings(defaultDeviceID: "should-not-overwrite")
        XCTAssertEqual(reopenedSettings.deviceID, "iphone-17-test")

        let all = try store2.fetchNotifications()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].appLabel, "X")
        XCTAssertEqual(all[0].body, "test123")
        XCTAssertEqual(all[1].appLabel, "Gmail")
        XCTAssertEqual(all[1].subtitle, "billing@example.com")

        let filtered = try store2.fetchNotifications(appFilter: "Gmail")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].title, "Receipt")

        let searched = try store2.fetchNotifications(searchText: "test123")
        XCTAssertEqual(searched.count, 1)
        XCTAssertEqual(searched[0].appLabel, "X")
    }

    func testDuplicateInsertWithinBucketIsIdempotent() throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        let p1 = IncomingNotificationPayload(
            app: "WeChat",
            title: "Lin",
            subtitle: "",
            body: "On my way",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_010)
        )
        let p2 = IncomingNotificationPayload(
            app: "WeChat",
            title: "Lin",
            subtitle: nil,
            body: "On my way",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_025)
        )

        let o1 = try service.ingest(p1)
        let o2 = try service.ingest(p2)

        guard case .captured(let firstRecord) = o1 else {
            return XCTFail("Expected .captured, got \(o1)")
        }
        guard case .duplicate(let secondRecord) = o2 else {
            return XCTFail("Expected .duplicate, got \(o2)")
        }
        XCTAssertEqual(firstRecord.captureUUID, secondRecord.captureUUID)
        XCTAssertEqual(try service.notifications().count, 1)

        // Identical text arriving after the 60s sliding window stays a distinct notification.
        let p3 = IncomingNotificationPayload(
            app: "WeChat",
            title: "Lin",
            subtitle: nil,
            body: "On my way",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_100)
        )
        let o3 = try service.ingest(p3)
        guard case .captured(let thirdRecord) = o3 else {
            return XCTFail("Expected later message to be captured, got \(o3)")
        }
        XCTAssertNotEqual(firstRecord.captureUUID, thirdRecord.captureUUID)
        XCTAssertEqual(try service.notifications().count, 2)
    }

    // MARK: - TLA+ Invariant Alignment (Pause, Toggle Filtering, Honest Verification)

    func testSelectedAppStartsUnverifiedAndOnlyBecomesVerifiedAfterShortcutDelivery() throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        let initial = try service.settings()
        let xApp = try XCTUnwrap(initial.apps.first(where: { $0.id == "x" }))
        XCTAssertTrue(xApp.enabled)
        XCTAssertFalse(initial.isVerified(app: xApp), "Selecting an app must never fabricate Shortcuts verification.")

        // Toggling an app must not fabricate verification either.
        let afterToggle = try service.updateSettings { state in
            if let idx = state.apps.firstIndex(where: { $0.id == "gmail" }) {
                state.apps[idx].enabled.toggle()
                state.apps[idx].enabled.toggle()
            }
        }
        let gmailApp = try XCTUnwrap(afterToggle.apps.first(where: { $0.id == "gmail" }))
        XCTAssertFalse(afterToggle.isVerified(app: gmailApp))

        // Receiving a Shortcuts payload verifies that app.
        _ = try service.ingest(IncomingNotificationPayload(
            app: "X",
            title: "Notifidex",
            body: "test123",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_300),
            channel: .iosShortcuts
        ))

        let afterDelivery = try service.settings()
        XCTAssertTrue(afterDelivery.isVerified(app: xApp))
        XCTAssertFalse(afterDelivery.isVerified(app: gmailApp))
    }

    func testDisabledAppAndPausedCaptureSkipWithoutWritingOrLosingExistingRecords() throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        // Capture one X alert first.
        let initialOutcome = try service.ingest(IncomingNotificationPayload(
            app: "X",
            title: "Notifidex",
            body: "before pause",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_400)
        ))
        guard case .captured = initialOutcome else {
            return XCTFail("Expected initial capture to succeed")
        }

        // Disable X dynamically inside Notifdex.
        _ = try service.updateSettings { state in
            if let idx = state.apps.firstIndex(where: { $0.id == "x" }) {
                state.apps[idx].enabled = false
            }
        }

        let disabledOutcome = try service.ingest(IncomingNotificationPayload(
            app: "X",
            title: "Notifidex",
            body: "while disabled",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_500)
        ))
        XCTAssertEqual(disabledOutcome, .skipped(.appDisabled("X")))
        XCTAssertEqual(try service.notifications().count, 1)

        // Global pause skips Gmail too while preserving prior records.
        _ = try service.updateSettings { $0.paused = true }
        let pausedOutcome = try service.ingest(IncomingNotificationPayload(
            app: "Gmail",
            title: "Update",
            body: "while paused",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_600)
        ))
        XCTAssertEqual(pausedOutcome, .skipped(.capturePaused))
        XCTAssertEqual(try service.notifications().count, 1)
    }

    // MARK: - App Intent Integration Handoff

    func testCaptureNotificationIntentHandoffPersistsAndLogsExecution() throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        let message = try CaptureNotificationIntent.execute(
            app: "X",
            title: "Notifidex",
            subtitle: "",
            body: "test123",
            receivedAt: Date(timeIntervalSince1970: 1_764_100_700),
            service: service
        )

        XCTAssertTrue(message.contains("Captured"), "Unexpected intent result: \(message)")
        let records = try service.notifications()
        XCTAssertEqual(records.count, 1)
        let firstRecord = try XCTUnwrap(records.first)
        XCTAssertEqual(firstRecord.appLabel, "X")
        XCTAssertEqual(firstRecord.title, "Notifidex")
        XCTAssertEqual(firstRecord.subtitle, "")
        XCTAssertEqual(firstRecord.body, "test123")
        XCTAssertEqual(firstRecord.captureChannel, .iosShortcuts)
        XCTAssertEqual(firstRecord.origin, .iphone)

        let logs = try service.executionLogs()
        XCTAssertEqual(logs.count, 1)
        let firstLog = try XCTUnwrap(logs.first)
        XCTAssertEqual(firstLog.appLabel, "X")
        XCTAssertEqual(firstLog.outcome, "captured")

        let stats = try service.stats()
        XCTAssertEqual(stats.totalCount, 1)
        XCTAssertEqual(stats.lastCapturedAt, 1_764_100_700)
        XCTAssertEqual(stats.countByApp["X"], 1)
    }

    // MARK: - Phase 2 Shared NotifdexCore & Hybrid Sync on iOS

    func testIOSShortcutsCaptureFeedsSharedNotifdexCoreWorkflowsAndSync() async throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        _ = try CaptureNotificationIntent.execute(
            app: "Gmail",
            title: "Alex",
            subtitle: "Launch",
            body: "Ready for review",
            receivedAt: Date(timeIntervalSince1970: 1_764_200_000),
            service: service
        )

        let items = try service.hybridInbox()
        XCTAssertEqual(items.count, 1)
        let entry = try XCTUnwrap(items.first?.primary)
        XCTAssertEqual(entry.app, "Gmail")
        XCTAssertEqual(items.first?.provenanceBadges, ["iPhone"])

        // Exercise shared NotifdexCore workflows (flag, save, follow-up, person, note).
        try service.setFlag(entry.id, flagged: true)
        try service.setSaved(entry.id, saved: true)
        try service.scheduleFollowUp(entry.id, dueAt: 1_764_250_000)
        let personID = try service.createPerson(name: "Alex Morgan", linking: entry.id)
        try service.addPersonNote(personID: personID, title: "Launch", body: "Send checklist")
        try service.savePersonalNote(folderID: nil, title: "Scratch", body: "Test iOS note")

        XCTAssertEqual(try service.followUps().count, 1)
        XCTAssertEqual(try service.people().count, 1)
        XCTAssertEqual(try service.personNotes(for: personID).count, 1)
        XCTAssertEqual(try service.personalNotes().count, 1)

        // Pair and sync iOS -> Mac through shared HybridSyncCoordinator.
        try service.enableAndPairLocalSync(displayName: "Jared's iPhone")
        let transport = InMemorySyncTransport()
        let syncResult = try await service.runSync(using: transport)
        XCTAssertEqual(syncResult.pushedObservations, 1)

        let macDB = tempDir.appendingPathComponent("mac-capture.db")
        let macStore = try CaptureStore(path: macDB.path)
        try macStore.pairDevice(deviceID: "mac-mini", displayName: "Jared's Mac", platform: .mac)
        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let macResult = try await macCoord.syncNow(localDeviceID: "mac-mini")

        XCTAssertEqual(macResult.applied.insertedObservations, 1)
        let macEntry = try XCTUnwrap(try macStore.inbox(InboxQuery()).first)
        XCTAssertTrue(macEntry.isFlagged)
        XCTAssertTrue(macEntry.saved)
        XCTAssertEqual(macEntry.personName, "Alex Morgan")
        XCTAssertEqual(try macStore.personalNotes().count, 1)
    }

    func testConcurrentBurstCaptureCompletesRapidlyUnderUIContention() async throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)
        let start = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for idx in 0..<25 {
                group.addTask {
                    _ = try CaptureNotificationIntent.execute(
                        app: idx.isMultiple(of: 2) ? "Gmail" : "X",
                        title: "Burst Sender \(idx)",
                        subtitle: "",
                        body: "Burst body \(idx)",
                        receivedAt: Date(timeIntervalSince1970: 1_764_300_000 + Double(idx)),
                        service: service
                    )
                }
            }
            for _ in 0..<10 {
                group.addTask {
                    _ = try service.hybridInbox()
                    _ = try service.stats()
                }
            }
            try await group.waitForAll()
        }

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "25 concurrent captures under UI contention took \(elapsed)s")
        XCTAssertEqual(try service.hybridInbox().count, 25)
    }

    func testIOSHideAlertRestoreAndHideRulesRoundTrip() throws {
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        _ = try CaptureNotificationIntent.execute(
            app: "Gmail",
            title: "Promo Bot",
            subtitle: "",
            body: "Flash sale 50% off",
            receivedAt: Date(timeIntervalSince1970: 1_764_400_000),
            service: service
        )
        _ = try CaptureNotificationIntent.execute(
            app: "Gmail",
            title: "Promo Bot",
            subtitle: "",
            body: "Another promo",
            receivedAt: Date(timeIntervalSince1970: 1_764_400_100),
            service: service
        )
        _ = try CaptureNotificationIntent.execute(
            app: "X",
            title: "Alice",
            subtitle: "",
            body: "Real message",
            receivedAt: Date(timeIntervalSince1970: 1_764_400_200),
            service: service
        )

        XCTAssertEqual(try service.hybridInbox().count, 3)

        // Hide one alert individually -> moves to Hidden; restore brings it back.
        let alice = try XCTUnwrap(try service.hybridInbox().first(where: { $0.primary.title == "Alice" }))
        try service.hideAlert(alice.primary.id)
        XCTAssertEqual(try service.hybridInbox().count, 2)
        XCTAssertEqual(try service.hybridInbox(scope: .hidden(app: nil)).count, 1)

        try service.restoreAlert(alice.primary.id)
        XCTAssertEqual(try service.hybridInbox().count, 3)
        XCTAssertEqual(try service.hybridInbox(scope: .hidden(app: nil)).count, 0)

        // Add a title hide rule -> hides both Gmail Promo Bot alerts; removing restores both.
        let rule = InboxRuleMatch(app: "Gmail", field: .title, text: "Promo Bot")
        XCTAssertTrue(try service.addHideRule(rule))
        XCTAssertEqual(try service.inboxFilters().count, 1)
        XCTAssertEqual(try service.hybridInbox().count, 1)
        XCTAssertEqual(try service.hybridInbox(scope: .hidden(app: nil)).count, 2)

        try service.removeHideRule(rule)
        XCTAssertEqual(try service.inboxFilters().count, 0)
        XCTAssertEqual(try service.hybridInbox().count, 3)
    }

    func testIngestUsesSingleCoreStoreWithoutWritingLegacyPhase1TableAndMigratesLegacyRows() throws {
        // 1. Fresh ingest must persist only to shared NotifdexCore and never write to legacy ios-capture.db notifications table.
        let store = try NotificationStore(databaseURL: dbURL)
        let service = CaptureService(store: store)

        let outcome = try service.ingest(IncomingNotificationPayload(
            app: "X",
            title: "Sam",
            subtitle: "DM",
            body: "Single store test",
            receivedAt: Date(timeIntervalSince1970: 1_764_500_000)
        ))
        guard case .captured(let captured) = outcome else {
            return XCTFail("Expected .captured, got \(outcome)")
        }
        XCTAssertEqual(captured.appLabel, "X")
        XCTAssertEqual(try store.fetchNotifications().count, 0, "New captures must not dual-write to legacy Phase 1 notifications table")
        XCTAssertEqual(try service.coreStore.observationCount(), 1)
        XCTAssertEqual(try service.notifications().count, 1)
        XCTAssertEqual(try service.stats().totalCount, 1)
        XCTAssertEqual(try service.stats().countByApp["X"], 1)

        // 2. Existing Phase 1 legacy rows still migrate non-destructively into an empty coreStore on startup.
        let legacyDir = tempDir.appendingPathComponent("legacy-migration", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacyDB = legacyDir.appendingPathComponent("ios-capture.db")
        let legacyStore = try NotificationStore(databaseURL: legacyDB)
        let legacySettings = try legacyStore.loadOrCreateSettings(defaultDeviceID: "legacy-iphone")
        let normalized = try XCTUnwrap(CaptureNormalizer.normalize(IncomingNotificationPayload(
            app: "Gmail",
            title: "Legacy",
            subtitle: nil,
            body: "Migrated from Phase 1",
            receivedAt: Date(timeIntervalSince1970: 1_764_500_100)
        )))
        _ = try legacyStore.insertNotification(normalized, sourceID: legacySettings.sourceID, deviceID: legacySettings.deviceID)

        let migratedService = CaptureService(store: legacyStore)
        XCTAssertEqual(try migratedService.coreStore.observationCount(), 1)
        XCTAssertEqual(try migratedService.stats().countByApp["Gmail"], 1)
    }
}
