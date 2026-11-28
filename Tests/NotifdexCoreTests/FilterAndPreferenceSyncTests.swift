import CSQLite
import Foundation
import XCTest
@testable import NotifdexCore

final class FilterAndPreferenceSyncTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotifdexFilterSyncTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Bidirectional App, Title, and Body/Subject Hide Rules

    func testHideRulesSyncMacToIOSAndReverseIncludingAppTitleAndBody() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        // Seed alerts on iOS (from Discord, Gmail, Slack, X).
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts", originDeviceID: iosID,
            appLabel: "Discord", title: "General", body: "Server ping", capturedAt: 110
        )
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts", originDeviceID: iosID,
            appLabel: "Gmail", title: "CI Bot", body: "Nightly digest", capturedAt: 111
        )
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts", originDeviceID: iosID,
            appLabel: "Slack", title: "Build Alerts", body: "Deploy green", capturedAt: 112
        )
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts", originDeviceID: iosID,
            appLabel: "X", title: "Alice", body: "Lunch today?", capturedAt: 113
        )

        // On Mac: add an app-level rule (Discord) and a body/subject rule (Gmail).
        let discordAppRule = InboxRuleMatch(app: "Discord", field: .app, text: "Discord")
        let gmailBodyRule = InboxRuleMatch(app: "Gmail", field: .body, text: "Nightly digest")
        XCTAssertTrue(try macStore.addHideRule(discordAppRule, at: 120))
        XCTAssertTrue(try macStore.addHideRule(gmailBodyRule, at: 121))

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)

        _ = try await macCoord.syncNow(localDeviceID: macID, at: 125)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 130)

        // iOS must immediately reflect Mac's app-level and body-level hide rules.
        let iosVisibleAfterMacRules = try iosStore.inbox(InboxQuery())
        XCTAssertEqual(Set(iosVisibleAfterMacRules.map(\.app)), Set(["Slack", "X"]))
        let iosHiddenAfterMacRules = try iosStore.inbox(InboxQuery(scope: .hidden(app: nil)))
        XCTAssertEqual(Set(iosHiddenAfterMacRules.map(\.app)), Set(["Discord", "Gmail"]))
        XCTAssertEqual(iosHiddenAfterMacRules.first(where: { $0.app == "Discord" })?.appFiltered, true)

        // Reverse direction: on iOS add a title rule for Slack ("Build Alerts"), sync back to Mac.
        let slackTitleRule = InboxRuleMatch(app: "Slack", field: .title, text: "Build Alerts")
        XCTAssertTrue(try iosStore.addHideRule(slackTitleRule, at: 140))

        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 145)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 150)

        let macRules = try macStore.inboxFilters()
        XCTAssertEqual(macRules.count, 3)
        XCTAssertTrue(macRules.contains(where: { $0.match == slackTitleRule && $0.enabled }))
        let macVisible = try macStore.inbox(InboxQuery())
        XCTAssertEqual(macVisible.map(\.app), ["X"])
    }

    // MARK: - Disable, Remove, Undo (Re-create), and Stale Offline Retry

    func testDisableRemoveAndUndoRulePropagatesWithoutStaleResurrection() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let rule = InboxRuleMatch(app: "Gmail", field: .title, text: "Promo Bot")
        _ = try iosStore.recordDirectObservation(
            sourceID: "\(iosID):ios_shortcuts", originDeviceID: iosID,
            appLabel: "Gmail", title: "Promo Bot", body: "Sale!", capturedAt: 105
        )
        _ = try macStore.addHideRule(rule, at: 110)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 115)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 120)
        XCTAssertTrue(try iosStore.inbox(InboxQuery()).isEmpty)

        // 1. Disable rule on Mac -> sync to iOS -> alert becomes visible again, rule stays stored as disabled.
        try macStore.setHideRuleEnabled(rule, enabled: false, at: 130)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 135)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 140)
        XCTAssertEqual(try iosStore.inbox(InboxQuery()).count, 1)
        XCTAssertEqual(try iosStore.inboxFilters().first?.enabled, false)

        // 2. Remove rule on Mac -> sync to iOS -> tombstone removes it on iOS too.
        try macStore.removeHideRule(rule, at: 150)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 155)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 160)
        XCTAssertTrue(try iosStore.inboxFilters().isEmpty)

        // 3. Replaying an older stale batch with the deleted rule (updatedAt 110 <= deletedAt 150)
        //    must NOT resurrect the deleted rule.
        let staleBatch = SyncBatch(
            senderDeviceID: "stale-device",
            exportedAt: 165,
            hideRules: [SyncedHideRuleRecord(app: "Gmail", field: .title, value: "Promo Bot", enabled: true, updatedAt: 110)]
        )
        _ = try iosStore.applySyncBatch(staleBatch, localDeviceID: iosID, at: 166)
        XCTAssertTrue(try iosStore.inboxFilters().isEmpty)

        // 4. Undo / re-create rule on iOS at a strictly newer timestamp (180 > 150) -> syncs back to Mac!
        XCTAssertTrue(try iosStore.addHideRule(rule, at: 180))
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 185)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 190)
        XCTAssertEqual(try macStore.inboxFilters().count, 1)
        XCTAssertEqual(try macStore.inboxFilters().first?.enabled, true)
    }

    // MARK: - Concurrent Conflicting Edits & Duplicate Prevention

    func testSimultaneousRuleConflictResolvesDeterministicallyWithoutDuplicates() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let rule = InboxRuleMatch(app: "X", field: .title, text: "Spam Account")

        // Both devices create the same rule offline; iPhone disables it at the exact same timestamp (200).
        _ = try macStore.addHideRule(rule, at: 200)
        _ = try iosStore.addHideRule(rule, at: 199)
        try iosStore.setHideRuleEnabled(rule, enabled: false, at: 200)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)

        // Sync both ways (twice to cover duplicate delivery / idempotence).
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 210)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 211)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 212)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 213)

        // Conservative tie-breaking: enabled (hide) wins at equal timestamp; zero duplicate rows.
        let macRules = try macStore.inboxFilters()
        let iosRules = try iosStore.inboxFilters()
        XCTAssertEqual(macRules.count, 1)
        XCTAssertEqual(iosRules.count, 1)
        XCTAssertTrue(macRules[0].enabled)
        XCTAssertTrue(iosRules[0].enabled)
    }

    // MARK: - Individual Alert Hide / Restore & Read (Dimmed) Without Leaking Never-Synced Hidden Content

    func testIndividualHideRestoreAndReadPropagateWithoutLeakingPrivateHiddenContent() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter", sourceEventID: "ev-shared", capturedAt: 110,
            description: "X, Bob, Meeting at 3pm, from iPhone", title: "Bob", body: "Meeting at 3pm"
        ), runID: runID)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter", sourceEventID: "ev-secret", capturedAt: 111,
            description: "Messages, Private, Secret code 999, from iPhone", title: "Private", body: "Secret code 999"
        ), runID: runID)

        // Hide ev-secret locally on Mac BEFORE first sync; mark ev-shared read BEFORE first sync.
        let initialMac = try macStore.inbox(InboxQuery())
        let secret = try XCTUnwrap(initialMac.first(where: { $0.title == "Private" }))
        let shared = try XCTUnwrap(initialMac.first(where: { $0.title == "Bob" }))
        try macStore.hideAlert(secret.id, at: 112)
        try macStore.setRead(shared.id, read: true)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 115)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 120)

        // Verify ev-secret NEVER leaked to CloudKit or iOS, while ev-shared arrived already read!
        let batches = await transport.allPushedBatches()
        XCTAssertFalse(batches.flatMap(\.observations).contains(where: { $0.body.contains("Secret code") }))
        let iosInbox1 = try iosStore.inbox(InboxQuery())
        XCTAssertEqual(iosInbox1.count, 1)
        XCTAssertEqual(iosInbox1[0].title, "Bob")
        XCTAssertTrue(iosInbox1[0].isRead, "Read/dimmed state set before first sync must still propagate.")

        // Now hide the already-synced Bob alert on Mac -> sync -> Bob hides on iOS too!
        try macStore.hideAlert(shared.id, at: 130)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 135)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 140)
        XCTAssertTrue(try iosStore.inbox(InboxQuery()).isEmpty)
        XCTAssertEqual(try iosStore.inbox(InboxQuery(scope: .hidden(app: nil))).map(\.title), ["Bob"])

        // Restore/undo on iOS -> sync -> restored on Mac too!
        let iosBob = try XCTUnwrap(try iosStore.inbox(InboxQuery(scope: .hidden(app: nil))).first)
        try iosStore.restoreAlert(iosBob.id, at: 150)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 155)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 160)
        XCTAssertEqual(try macStore.inbox(InboxQuery()).map(\.title), ["Bob"])
    }

    // MARK: - Full CRM, Workspaces, Templates, Tombstones & Preferences

    func testWorkspacesIdentitiesTemplatesAndAutomaticDeleteTombstonesSync() async throws {
        let macStore = try makeStore(named: "mac")
        let iosStore = try makeStore(named: "ios")
        let transport = InMemorySyncTransport()

        let macID = "mac-mini"
        let iosID = "iphone-17"
        try macStore.pairDevice(deviceID: macID, displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: iosID, displayName: "iPhone", platform: .iphone, at: 100)

        let runID = try macStore.startRun(at: 100)
        try macStore.record(Observation(
            sourceID: "\(macID):notificationcenter", sourceEventID: "ev-founder", capturedAt: 110,
            description: "X, Maya Lin, Deck attached, from iPhone", title: "Maya Lin", body: "Deck attached"
        ), runID: runID)

        let entry = try XCTUnwrap(try macStore.inbox(InboxQuery()).first)
        let wsID = try macStore.createWorkspace(name: "Founders")
        let personID = try macStore.createPerson(
            name: "Maya Lin",
            linking: entry.id,
            workspace: wsID,
            identity: (platform: "X", identifier: "@mayalin"),
            rememberMatch: true
        )
        try macStore.setAlertWorkspace(entry.id, to: wsID)
        let template = try macStore.installTemplate(RelationshipTemplate.bundledFounderOutreach())
        _ = try macStore.applyTemplate(template, to: personID)
        try macStore.setTemplateStage("evaluating", for: personID)
        try macStore.setTemplateMilestone("joined-slack", completed: true, for: personID)

        let folderID = try macStore.saveNoteFolder(name: "Deals")
        let noteID = try macStore.savePersonalNote(folderID: folderID, title: "Intro", body: "Great team", at: 120)
        try macStore.saveSharedPreferences(
            SyncedUserPreferences(colorThemeRaw: AppColorTheme.prussian.rawValue, groupByApp: true, updatedAt: 125)
        )

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 130)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 135)

        // Verify everything arrived cleanly on iOS.
        XCTAssertEqual(try iosStore.workspaces().map(\.name), ["Founders"])
        XCTAssertEqual(try iosStore.workspaceIDs(for: personID), [wsID])
        XCTAssertEqual(try iosStore.inbox(InboxQuery()).first?.workspaceID, wsID)
        XCTAssertEqual(try iosStore.identities(for: personID).map(\.identifier), ["@mayalin"])
        XCTAssertEqual(try iosStore.personMatchRules(for: personID).count, 1)
        let iosTemplate = try XCTUnwrap(try iosStore.templateAssignment(for: personID))
        XCTAssertEqual(iosTemplate.stageID, "evaluating")
        XCTAssertEqual(iosTemplate.completedMilestones, ["joined-slack"])
        XCTAssertEqual(try iosStore.sharedPreferences()?.colorThemeRaw, AppColorTheme.prussian.rawValue)
        XCTAssertEqual(try iosStore.sharedPreferences()?.groupByApp, true)

        // Delete personal note & folder directly via CaptureStore on Mac (no manual tombstone call!)
        // and verify tombstones automatically propagate to iOS.
        try macStore.deletePersonalNote(noteID)
        try macStore.deleteNoteFolder(folderID)
        _ = try await macCoord.syncNow(localDeviceID: macID, at: 150)
        _ = try await iosCoord.syncNow(localDeviceID: iosID, at: 155)
        XCTAssertTrue(try iosStore.personalNotes().isEmpty)
        XCTAssertTrue(try iosStore.noteFolders().isEmpty)
    }

    // MARK: - Migration from v12 & Device-Local Settings / Revocation Cleanup

    func testV12DatabaseMigratesExistingHideRulesAndRevocationClearsSyncCursors() async throws {
        let dbURL = tempDir.appendingPathComponent("legacy-v12.db")
        do {
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
            defer { sqlite3_close(db) }
            for name in ["schema", "inbox-work", "filters", "person-matches", "person-notes",
                         "flags", "hide-rules", "relationship-templates", "workspaces", "notebook", "sync"] {
                XCTAssertEqual(sqlite3_exec(db, try CaptureStore.schema(named: name), nil, nil, nil), SQLITE_OK)
            }
            let fixture = """
                PRAGMA user_version = 12;
                INSERT INTO inbox_filters (id, app, field, value) VALUES (5, 'Gmail', 'title', 'Legacy Bot');
                """
            XCTAssertEqual(sqlite3_exec(db, fixture, nil, nil, nil), SQLITE_OK)
        }

        let macStore = try CaptureStore(path: dbURL.path)
        let migratedRules = try macStore.inboxFilters()
        XCTAssertEqual(migratedRules.count, 1)
        XCTAssertEqual(migratedRules[0].match, InboxRuleMatch(app: "Gmail", field: .title, text: "Legacy Bot"))
        XCTAssertTrue(migratedRules[0].enabled)

        // Pair, sync to iOS, and confirm migrated v12 rule propagates.
        let iosStore = try makeStore(named: "ios-migrated")
        let transport = InMemorySyncTransport()
        try macStore.pairDevice(deviceID: "mac-v12", displayName: "Mac", platform: .mac, at: 100)
        try iosStore.pairDevice(deviceID: "ios-v12", displayName: "iPhone", platform: .iphone, at: 100)

        let macCoord = HybridSyncCoordinator(store: macStore, transport: transport)
        let iosCoord = HybridSyncCoordinator(store: iosStore, transport: transport)
        _ = try await macCoord.syncNow(localDeviceID: "mac-v12", at: 110)
        _ = try await iosCoord.syncNow(localDeviceID: "ios-v12", at: 115)
        XCTAssertEqual(try iosStore.inboxFilters().map(\.match), [InboxRuleMatch(app: "Gmail", field: .title, text: "Legacy Bot")])

        // Revoking local device clears stale change token and pushed digest while preserving local data.
        XCTAssertNotNil(try macStore.syncChangeToken())
        XCTAssertNotNil(try macStore.lastPushedDigest())
        try macStore.revokeDevice("mac-v12", at: 120)
        XCTAssertNil(try macStore.syncChangeToken())
        XCTAssertNil(try macStore.lastPushedDigest())
        XCTAssertEqual(try macStore.inboxFilters().count, 1)
    }

    func testV1SyncBatchDecodesBackwardCompatibly() throws {
        // Simulates an existing v1 SyncBatch payload already stored in Production CloudKit.
        let v1JSON = """
        {
          "schemaVersion": 1,
          "senderDeviceID": "legacy-mac",
          "exportedAt": 1764200000,
          "observations": [],
          "workflows": [{
            "syncUUID": "u-1",
            "isRead": true,
            "isFlagged": false,
            "saved": true,
            "done": false,
            "workflowVersion": 2,
            "updatedAt": 1764200000
          }],
          "people": [{"id": "p-1", "displayName": "Alex"}],
          "personNotes": [],
          "noteFolders": [{"id": "f-1", "name": "Work"}],
          "personalNotes": [],
          "tombstones": []
        }
        """
        let batch = try JSONDecoder().decode(SyncBatch.self, from: Data(v1JSON.utf8))
        XCTAssertEqual(batch.schemaVersion, 1)
        XCTAssertEqual(batch.workflows.count, 1)
        XCTAssertNil(batch.workflows[0].workspaceID)
        XCTAssertTrue(batch.hideRules.isEmpty)
        XCTAssertTrue(batch.hiddenAlerts.isEmpty)
        XCTAssertNil(batch.preferences)
    }
}
