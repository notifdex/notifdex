import XCTest
@testable import NotifdexCore

final class HybridSyncTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifdexHybridSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeStore(named name: String) throws -> CaptureStore {
        try CaptureStore(path: tempDir.appendingPathComponent("\(name).db").path)
    }

    // MARK: - Opt-in & Revocation

    func testSyncStartsDisabledAndUnpairedDevicesCannotSync() async throws {
        let macStore = try makeStore(named: "mac")
        let transport = InMemorySyncTransport()
        let coordinator = HybridSyncCoordinator(store: macStore, transport: transport)

        XCTAssertFalse(try macStore.isSyncEnabled())
        let macID = try macStore.localSyncDeviceID()
        XCTAssertFalse(try macStore.canDeviceSync(macID))

        do {
            _ = try await coordinator.syncNow(localDeviceID: macID, at: 1_764_200_000)
            XCTFail("Expected unpaired device sync to throw")
        } catch {
            let pushed = await transport.allPushedBatches()
            XCTAssertTrue(pushed.isEmpty)
        }
    }

    func testRevokingDeviceStopsSyncWithoutLosingLocalEvidence() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Jared's Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "Jared's iPhone", platform: .iphone, at: 100)

        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "X",
            title: "Notifidex",
            body: "before revoke",
            capturedAt: 200
        )

        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        let first = try await iosCoord.syncNow(localDeviceID: iosID, at: 205)
        XCTAssertEqual(first.pushedObservations, 1)

        // One-tap revoke on iPhone.
        try iosStore.revokeDevice(iosID, at: 210)
        XCTAssertFalse(try iosStore.canDeviceSync(iosID))

        // Local evidence must remain intact after revocation.
        XCTAssertEqual(try iosStore.observationCount(), 1)

        do {
            _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 220)
            XCTFail("Expected revoked device to be rejected")
        } catch {
            let pushed = await transport.allPushedBatches()
            XCTAssertEqual(pushed.count, 1)
        }
    }

    // MARK: - Filtered Projection (HiddenNeverLeaksToCloudOrIPhone)

    func testHiddenAndRuleFilteredAlertsNeverLeakToIPhone() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "ev-visible",
            capturedAt: 110,
            description: "X, Alice, Need your review, from iPhone",
            title: "Alice",
            body: "Need your review"
        ), runID: runID)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "ev-hidden-individual",
            capturedAt: 111,
            description: "X, Promo, Limited offer, from iPhone",
            title: "Promo",
            body: "Limited offer"
        ), runID: runID)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "ev-hidden-rule",
            capturedAt: 112,
            description: "Gmail, Newsletter, Weekly digest, from iPhone",
            title: "Newsletter",
            body: "Weekly digest"
        ), runID: runID)

        let macRows = try macStore.inbox(InboxQuery())
        let promo = try XCTUnwrap(macRows.first(where: { $0.title == "Promo" }))
        try macStore.hideAlert(promo.id)
        _ = try macStore.addHideRule(InboxRuleMatch(app: "Gmail", field: .title, text: "Newsletter"))

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)

        let macSync = try await macCoord.syncNow(localDeviceID: macID, at: 120)
        XCTAssertEqual(macSync.pushedObservations, 1, "Only the single non-hidden alert should be pushed.")

        let iosSync = try await iosCoord.syncNow(localDeviceID: iosID, at: 125)
        XCTAssertEqual(iosSync.applied.insertedObservations, 1)

        let iosInbox = try iosStore.inbox(InboxQuery())
        XCTAssertEqual(iosInbox.count, 1)
        XCTAssertEqual(iosInbox.first?.title, "Alice")
    }

    // MARK: - Bidirectional Workflow Round-Trip & Tombstones

    func testBidirectionalWorkflowEditsAndNotesRoundTripBetweenMacAndIPhone() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        // Mac captures alert and pushes.
        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "ev-1",
            capturedAt: 200,
            description: "Gmail, Sam, Contract draft ready, from iPhone",
            title: "Sam",
            body: "Contract draft ready"
        ), runID: runID)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)

        _ = try await macCoord.syncNow(localDeviceID: macID, at: 205)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 210)

        // On iPhone: flag, save, schedule follow-up, create Person + Note, and add Personal Note.
        let iosEntry = try XCTUnwrap(try iosStore.inbox(InboxQuery()).first)
        try iosStore.setRead(iosEntry.id, read: true)
        try iosStore.setFlag(iosEntry.id, flagged: true)
        try iosStore.setSaved(iosEntry.id, saved: true)
        try iosStore.schedule(iosEntry.id, dueAt: 500)
        let personID = try iosStore.createPerson(name: "Sam Rivera", linking: iosEntry.id)
        _ = try iosStore.addPersonNote(person: personID, title: "Contract", body: "Send redlines tomorrow", at: 220)
        let noteID = try iosStore.savePersonalNote(folderID: nil, title: "Mobile Idea", body: "Follow up on Q4", at: 225)
        try iosStore.bumpWorkflowVersion(for: iosEntry.id, originDeviceID: iosID, at: 230)

        // Push from iPhone, pull on Mac.
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 235)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 240)

        let macEntry = try XCTUnwrap(try macStore.inbox(InboxQuery()).first)
        XCTAssertTrue(macEntry.isRead)
        XCTAssertTrue(macEntry.isFlagged)
        XCTAssertTrue(macEntry.saved)
        XCTAssertEqual(macEntry.dueAt, 500)
        XCTAssertEqual(macEntry.personName, "Sam Rivera")
        XCTAssertEqual(try macStore.personNotes(for: personID).first?.body, "Send redlines tomorrow")
        XCTAssertEqual(try macStore.personalNotes().count, 1)

        // Delete personal note on Mac with tombstone; stale iPhone replay must not resurrect it.
        try macStore.deletePersonalNote(noteID)
        try macStore.recordSyncTombstone(entityType: "personal_note", entityID: noteID, at: 250)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 255)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 260)

        XCTAssertTrue(try iosStore.personalNotes().isEmpty)
        XCTAssertTrue(try macStore.personalNotes().isEmpty)
    }

    // MARK: - Hybrid Provenance Collapsing & Direct iOS Capture

    func testHybridInboxCollapsesDuplicateMacAndIPhoneCapturesWhilePreservingProvenance() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        // Both Mac AX and iPhone Shortcuts capture the same X alert 4 seconds apart.
        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "mac-ax-1",
            capturedAt: 1_000,
            description: "X, Notifidex, test123, from iPhone",
            title: "Notifidex",
            body: "test123"
        ), runID: runID)

        let direct = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "X",
            title: "Notifidex",
            body: "test123",
            capturedAt: 1_004
        )
        XCTAssertTrue(direct.inserted)

        // Rapid retry 15s later across minute boundary deduplicates cleanly.
        let retry = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "X",
            title: "Notifidex",
            body: "test123",
            capturedAt: 1_019
        )
        XCTAssertFalse(retry.inserted)
        XCTAssertEqual(retry.syncUUID, direct.syncUUID)

        // Sync both ways.
        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 1_030)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 1_035)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 1_040)

        // Raw evidence from both devices is preserved in SQLite.
        XCTAssertEqual(try iosStore.observationCount(), 2)
        XCTAssertEqual(try macStore.observationCount(), 2)

        // Hybrid projection collapses them into ONE clean Inbox item with dual provenance.
        let entries = try iosStore.inbox(InboxQuery())
        let prov = try iosStore.provenanceByObservationID()
        let collapsed = HybridInboxProjection.collapse(entries, provenanceByID: prov)

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed[0].observationIDs.count, 2)
        XCTAssertTrue(collapsed[0].provenanceBadges.contains("iPhone"))
        XCTAssertTrue(collapsed[0].provenanceBadges.contains("iPhone via Mac"))
    }

    // MARK: - Dirty-Digest Push Skipping, Transient Failure Retry & Entitlement Safety

    func testUnchangedExportSkipsRedundantPushAndRetriesAfterFailure() async throws {
        let iosStore = try makeStore(named: "ios-retry")
        let iosID = "iphone-17"
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let obs = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "X",
            title: "Notifidex",
            body: "digest check",
            capturedAt: 200
        )

        let transport = FaultInjectingSyncTransport()
        let coordinator = HybridSyncCoordinator(store: iosStore, transport: transport)

        // First sync pushes the batch.
        let r1 = try await coordinator.syncNow(localDeviceID: iosID, at: 210)
        XCTAssertEqual(r1.pushedObservations, 1)
        let c1 = await transport.pushCount()
        XCTAssertEqual(c1, 1)

        // Second sync with zero local changes skips redundant push.
        let r2 = try await coordinator.syncNow(localDeviceID: iosID, at: 220)
        XCTAssertEqual(r2.pushedObservations, 0)
        let c2 = await transport.pushCount()
        XCTAssertEqual(c2, 1)

        // Local workflow edit marks state dirty; injected push failure must NOT clear dirty digest.
        try iosStore.setFlag(obs.observationID, flagged: true)
        try iosStore.bumpWorkflowVersion(for: obs.observationID, originDeviceID: iosID, at: 230)
        await transport.setFailNextPush(true)

        do {
            _ = try await coordinator.syncNow(localDeviceID: iosID, at: 235)
            XCTFail("Expected injected CloudKit push failure to throw")
        } catch {
            let cFail = await transport.pushCount()
            XCTAssertEqual(cFail, 1)
        }

        // Next sync retries and succeeds.
        let r3 = try await coordinator.syncNow(localDeviceID: iosID, at: 240)
        XCTAssertEqual(r3.pushedObservations, 1)
        let c3 = await transport.pushCount()
        XCTAssertEqual(c3, 2)
    }

    // MARK: - macOS Forwarding Outage Resilience & Health Detection

    func testMacForwardingHealthDetectsOutageWhileIgnoringNativeAppsAndClearsOnRecovery() async throws {
        let macStore = try makeStore(named: "mac-fwd-health")
        let iosStore = try makeStore(named: "ios-fwd-health")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"

        // Unpaired Mac must never false-alarm.
        let unpairedReport = try macStore.macForwardingHealth(
            localDeviceID: macID,
            enabledApps: ["Gmail", "X", "WeChat"],
            now: 1_000
        )
        XCTAssertEqual(unpairedReport.status, .inactive)
        XCTAssertTrue(unpairedReport.affectedApps.isEmpty)

        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        // Paired with no recent iOS alerts is inactive (no false alarm).
        let emptyReport = try macStore.macForwardingHealth(
            localDeviceID: macID,
            enabledApps: ["Gmail", "X", "WeChat"],
            now: 1_000
        )
        XCTAssertEqual(emptyReport.status, .inactive)

        // Simulate macOS -10814 remote-placeholder outage:
        // Native Mac WeChat still arrives locally on Mac, while forwarded Gmail & X are dropped on Mac
        // and captured only by iPhone Shortcuts.
        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "mac-wechat-1",
            capturedAt: 1_000,
            description: "WeChat, Lin, Dinner at 7?",
            title: "Lin",
            body: "Dinner at 7?"
        ), runID: runID)

        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "WeChat",
            title: "Lin",
            body: "Dinner at 7?",
            capturedAt: 1_001
        )
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "Gmail",
            title: "Alex",
            body: "Invoice attached",
            capturedAt: 1_010
        )
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts",
            originDeviceID: iosID,
            appLabel: "X",
            title: "Sam",
            body: "Mentioned you",
            capturedAt: 1_020
        )

        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 1_030)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 1_035)

        // Hybrid sync preserved Gmail & X on Mac despite macOS dropping forwarded alerts.
        let macInbox = try macStore.inbox(InboxQuery())
        XCTAssertTrue(macInbox.contains(where: { $0.app == "Gmail" && $0.title == "Alex" }))
        XCTAssertTrue(macInbox.contains(where: { $0.app == "X" && $0.title == "Sam" }))

        // Health analyzer flags Gmail and X as degraded, while WeChat (captured natively on Mac) is NOT flagged.
        let degraded = try macStore.macForwardingHealth(
            localDeviceID: macID,
            enabledApps: ["WeChat", "Gmail", "X"],
            now: 1_050
        )
        XCTAssertEqual(degraded.status, .degraded)
        XCTAssertEqual(degraded.affectedApps, ["Gmail", "X"])
        XCTAssertEqual(degraded.iosOnlyAlertCount, 2)
        XCTAssertTrue(degraded.remediationHint?.contains("Allow notifications from iPhone") == true)

        // Recovery: after offloading/updating Gmail & X, macOS captures forwarded alerts again.
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "mac-gmail-recovered",
            capturedAt: 1_100,
            description: "Gmail, Alex, Invoice attached, from iPhone",
            title: "Alex",
            body: "Invoice attached"
        ), runID: runID)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "mac-x-recovered",
            capturedAt: 1_105,
            description: "X, Sam, Mentioned you, from iPhone",
            title: "Sam",
            body: "Mentioned you"
        ), runID: runID)

        let recovered = try macStore.macForwardingHealth(
            localDeviceID: macID,
            enabledApps: ["WeChat", "Gmail", "X"],
            now: 1_120
        )
        XCTAssertEqual(recovered.status, .healthy)
        XCTAssertTrue(recovered.affectedApps.isEmpty)
        XCTAssertEqual(recovered.macForwardedAlertCount, 2)

        // Dual-captured recovered alerts collapse cleanly without losing either provenance badge.
        let recoveredInbox = try macStore.inbox(InboxQuery())
        let prov = try macStore.provenanceByObservationID()
        let collapsed = HybridInboxProjection.collapse(recoveredInbox, provenanceByID: prov)
        XCTAssertEqual(collapsed.count, 3)
        let gmailItem = try XCTUnwrap(collapsed.first(where: { $0.primary.app == "Gmail" }))
        XCTAssertEqual(gmailItem.observationIDs.count, 2)
        XCTAssertTrue(gmailItem.provenanceBadges.contains("iPhone"))
        XCTAssertTrue(gmailItem.provenanceBadges.contains("iPhone via Mac"))
    }

    // MARK: - Automatic Bidirectional Sync (mirrors spec/AutoSync.tla)

    func testAutoSyncStateMachineEnforcesSingleFlightCoalescingBackoffAndRevocation() {
        var machine = AutoSyncStateMachine(
            debounceSeconds: 2.0,
            baseBackoffSeconds: 10.0,
            maxBackoffSeconds: 40.0,
            maxFailureStreak: 3
        )

        // Unpaired device never schedules auto-sync.
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.handleTrigger(.localCapture), .none)
        XCTAssertEqual(machine.phase, .idle)

        // Pairing with auto-sync enabled schedules an initial debounced sync.
        XCTAssertEqual(machine.setPaired(true), .scheduleAfter(2.0))
        XCTAssertEqual(machine.phase, .debouncing)

        // Burst triggers while debouncing coalesce without launching multiple runs.
        XCTAssertEqual(machine.handleTrigger(.localCapture), .none)
        XCTAssertEqual(machine.handleTrigger(.localEdit), .none)

        // Begin single-flight run; mid-sync trigger sets pendingTrigger instead of overlapping.
        XCTAssertTrue(machine.beginScheduledRun())
        XCTAssertEqual(machine.phase, .running)
        XCTAssertFalse(machine.beginScheduledRun())
        XCTAssertEqual(machine.handleTrigger(.localEdit), .none)
        XCTAssertTrue(machine.pendingTrigger)

        // Completing mid-sync run transitions to follow-up debounce (never drops mid-sync edit).
        XCTAssertEqual(machine.finishSuccess(), .scheduleAfter(2.0))
        XCTAssertEqual(machine.phase, .debouncing)
        XCTAssertEqual(machine.failureStreak, 0)

        // Transient failures apply bounded exponential backoff (10s -> 20s -> 40s -> 40s).
        XCTAssertTrue(machine.beginScheduledRun())
        XCTAssertEqual(machine.finishFailure(), .scheduleAfter(10.0))
        XCTAssertEqual(machine.phase, .backoff)
        XCTAssertEqual(machine.failureStreak, 1)

        XCTAssertTrue(machine.beginScheduledRun())
        XCTAssertEqual(machine.finishFailure(), .scheduleAfter(20.0))
        XCTAssertEqual(machine.failureStreak, 2)

        XCTAssertTrue(machine.beginScheduledRun())
        XCTAssertEqual(machine.finishFailure(), .scheduleAfter(40.0))
        XCTAssertEqual(machine.failureStreak, 3)

        XCTAssertTrue(machine.beginScheduledRun())
        XCTAssertEqual(machine.finishFailure(), .scheduleAfter(40.0))
        XCTAssertEqual(machine.failureStreak, 3)

        // Disabling auto-sync disarms backoff timer, but explicit manual sync still runs.
        machine.setAutoEnabled(false)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.handleTrigger(.periodic), .none)
        XCTAssertEqual(machine.handleTrigger(.manual), .runImmediately)
        XCTAssertEqual(machine.phase, .running)
        XCTAssertEqual(machine.finishSuccess(), .none)
        XCTAssertEqual(machine.failureStreak, 0)

        // Revoking immediately disarms scheduled work.
        machine.setAutoEnabled(true)
        XCTAssertEqual(machine.phase, .debouncing)
        machine.setPaired(false)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.pendingTrigger)
    }

    func testAutoSyncEngineBidirectionalCoalescedSyncAndLiveUpdateCallback() async throws {
        let macStore = try makeStore(named: "mac-auto")
        let iosStore = try makeStore(named: "ios-auto")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        XCTAssertTrue(try macStore.isAutoSyncEnabled())
        try macStore.setAutoSyncEnabled(false)
        XCTAssertFalse(try macStore.isAutoSyncEnabled())
        try macStore.setAutoSyncEnabled(true)
        XCTAssertTrue(try macStore.isAutoSyncEnabled())

        let appliedExpectation = expectation(description: "Mac auto-sync pulls remote iPhone alert")
        let iosCoordinator = HybridSyncCoordinator(store: iosStore, transport: transport)
        let macCoordinator = HybridSyncCoordinator(store: macStore, transport: transport)

        let iosEngine = AutoSyncEngine(
            debounceSeconds: 0.02,
            baseBackoffSeconds: 0.05,
            maxBackoffSeconds: 0.2,
            syncAction: { try await iosCoordinator.syncNow(localDeviceID: iosID, at: 200) }
        )
        let macEngine = AutoSyncEngine(
            debounceSeconds: 0.02,
            baseBackoffSeconds: 0.05,
            maxBackoffSeconds: 0.2,
            syncAction: { try await macCoordinator.syncNow(localDeviceID: macID, at: 210) },
            onSyncCompleted: { result in
                if result.applied.insertedObservations > 0 {
                    appliedExpectation.fulfill()
                }
            }
        )

        await iosEngine.configure(paired: true, autoEnabled: true)
        await macEngine.configure(paired: true, autoEnabled: true)

        // Burst 3 captures on iPhone; debounced auto-sync should push them cleanly.
        for i in 1...3 {
            _ = try iosStore.recordDirectObservation(
                sourceID: "\(iosID):ios_shortcuts",
                originDeviceID: iosID,
                appLabel: "Gmail",
                title: "Sender \(i)",
                body: "Body \(i)",
                capturedAt: Double(150 + i)
            )
            await iosEngine.trigger(.localCapture)
        }

        // Wait for iPhone auto-push to settle, then trigger Mac foreground auto-pull.
        try await Task.sleep(nanoseconds: 120_000_000)
        await macEngine.trigger(.foreground)
        await fulfillment(of: [appliedExpectation], timeout: 2.0)

        let macInbox = try macStore.inbox(InboxQuery())
        XCTAssertEqual(macInbox.count, 3)

        await iosEngine.stop()
        await macEngine.stop()
    }

    func testWorkflowUnflagOnMacOverridesOlderFlagOnIPhoneViaAutoVersionBump() async throws {
        let macStore = try makeStore(named: "mac-unflag")
        let iosStore = try makeStore(named: "ios-unflag")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter",
            sourceEventID: "ev-flag-toggle",
            capturedAt: 200,
            description: "X, Casey, Ping, from iPhone",
            title: "Casey",
            body: "Ping"
        ), runID: runID)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)

        _ = try await macCoord.syncNow(localDeviceID: macID, at: 205)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 210)

        // Flag on iPhone without manually calling bumpWorkflowVersion.
        let iosEntry = try XCTUnwrap(try iosStore.inbox(InboxQuery()).first)
        try iosStore.setFlag(iosEntry.id, flagged: true)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 220)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 225)

        let macFlagged = try XCTUnwrap(try macStore.inbox(InboxQuery()).first)
        XCTAssertTrue(macFlagged.isFlagged)

        // Now unflag on Mac without manually calling bumpWorkflowVersion; must sync back to iPhone as false.
        try macStore.setFlag(macFlagged.id, flagged: false)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 230)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 235)

        let iosAfter = try XCTUnwrap(try iosStore.inbox(InboxQuery()).first)
        XCTAssertFalse(iosAfter.isFlagged, "Unflagging on Mac must monotonically override older flag on iPhone")
    }

    #if canImport(CloudKit)
    func testCloudKitTransportGuardsMissingEntitlementWithoutCrashing() async throws {
        let transport = CloudKitSyncTransport()
        XCTAssertFalse(transport.hasCloudKitEntitlement())
        do {
            _ = try await transport.pull(since: nil)
            XCTFail("Expected clean StoreError when CloudKit entitlement is absent")
        } catch let err as StoreError {
            XCTAssertTrue(err.description.lowercased().contains("icloud") || err.description.lowercased().contains("entitlement"),
                          "Unexpected error message: \(err.description)")
        }
    }
    #endif
}

private actor FaultInjectingSyncTransport: SyncTransport {
    private let inner = InMemorySyncTransport()
    private var failNextPush = false
    private var pushes = 0

    func setFailNextPush(_ value: Bool) {
        failNextPush = value
    }

    func pushCount() -> Int {
        pushes
    }

    func push(_ batch: SyncBatch) async throws {
        if failNextPush {
            failNextPush = false
            throw StoreError(description: "Simulated transient CloudKit outage")
        }
        try await inner.push(batch)
        pushes += 1
    }

    func pull(since token: Data?) async throws -> SyncPullResult {
        try await inner.pull(since: token)
    }
}
