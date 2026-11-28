import Foundation
import NotifdexCore

public extension Notification.Name {
    static let notifdexCaptureStoreDidChange = Notification.Name("com.notifdex.ios.captureStoreDidChange")
}

/// Authoritative capture & workflow service shared by `CaptureNotificationIntent` and the SwiftUI app.
/// Mirrors `spec/IOSCapture.tla` and `spec/HybridSync.tla`, backed by shared `NotifdexCore.CaptureStore`.
public final class CaptureService: @unchecked Sendable {
    public static let shared: CaptureService = {
        do {
            let legacyURL = try CaptureService.defaultDatabaseURL()
            let coreURL = try CaptureService.defaultCoreDatabaseURL()
            let legacyStore = try NotificationStore(databaseURL: legacyURL)
            let coreStore = try CaptureStore(path: coreURL.path)
            return CaptureService(store: legacyStore, coreStore: coreStore)
        } catch {
            fatalError("Failed to initialize Notifdex iOS CaptureService: \(error)")
        }
    }()

    public let store: NotificationStore
    public let coreStore: CaptureStore
    private let ingestQueue = DispatchQueue(label: "com.notifdex.ios.ingest", qos: .userInitiated)

    public init(store: NotificationStore, coreStore: CaptureStore? = nil) {
        self.store = store
        if let coreStore {
            self.coreStore = coreStore
        } else {
            let coreURL = store.databaseURL
                .deletingLastPathComponent()
                .appendingPathComponent("notifdex-core.db")
            do {
                self.coreStore = try CaptureStore(path: coreURL.path)
            } catch {
                fatalError("Failed to initialize shared CaptureStore: \(error)")
            }
        }
        migratePhase1ObservationsIfNeeded()
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Notifdex", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ios-capture.db")
    }

    public static func defaultCoreDatabaseURL() throws -> URL {
        try defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("notifdex-core.db")
    }

    /// One-time non-destructive import of any Phase 1 records from `ios-capture.db` into shared `NotifdexCore.CaptureStore`.
    private func migratePhase1ObservationsIfNeeded() {
        ingestQueue.sync {
            guard (try? coreStore.observationCount()) == 0 else { return }
            guard let legacyRecords = try? store.fetchNotifications(limit: 500), !legacyRecords.isEmpty else { return }
            for item in legacyRecords.reversed() {
                let channel: SyncCaptureChannel = item.captureChannel == .manualTest ? .manualTest : .iosShortcuts
                _ = try? coreStore.recordDirectObservation(
                    sourceID: item.sourceID,
                    originDeviceID: item.deviceID,
                    appLabel: item.appLabel,
                    title: item.title,
                    subtitle: item.subtitle,
                    body: item.body,
                    capturedAt: item.capturedAt,
                    origin: .iphone,
                    channel: channel,
                    dedupWindowSeconds: 60.0
                )
            }
        }
    }

    public func ingest(_ payload: IncomingNotificationPayload) throws -> CaptureOutcome {
        try ingestQueue.sync {
            let now = payload.receivedAt.timeIntervalSince1970
            guard let normalized = CaptureNormalizer.normalize(payload) else {
                try? store.recordExecutionLog(
                    appLabel: payload.app.isEmpty ? "(empty)" : payload.app,
                    outcome: "skipped",
                    detail: CaptureSkipReason.emptyPayload.message,
                    at: now
                )
                return .skipped(.emptyPayload)
            }

            // Only real Shortcuts invocations verify that an Apple Shortcuts automation is delivering for this app.
            var settings = try store.loadOrCreateSettings()
            if payload.channel == .iosShortcuts {
                settings = try store.markAppVerified(normalized.appLabel)
            }

            if settings.paused {
                try? store.recordExecutionLog(
                    appLabel: normalized.appLabel,
                    outcome: "skipped",
                    detail: CaptureSkipReason.capturePaused.message,
                    at: normalized.capturedAt
                )
                notifyChanged()
                return .skipped(.capturePaused)
            }

            if !settings.isAppEnabled(normalized.appLabel) {
                let reason = CaptureSkipReason.appDisabled(normalized.appLabel)
                try? store.recordExecutionLog(
                    appLabel: normalized.appLabel,
                    outcome: "skipped",
                    detail: reason.message,
                    at: normalized.capturedAt
                )
                notifyChanged()
                return .skipped(reason)
            }

            do {
                let coreChannel: SyncCaptureChannel = payload.channel == .manualTest ? .manualTest : .iosShortcuts
                let (observationID, syncUUID, inserted) = try coreStore.recordDirectObservation(
                    sourceID: settings.sourceID,
                    originDeviceID: settings.deviceID,
                    appLabel: normalized.appLabel,
                    title: normalized.title,
                    subtitle: normalized.subtitle,
                    body: normalized.body,
                    capturedAt: normalized.capturedAt,
                    origin: .iphone,
                    channel: coreChannel,
                    dedupWindowSeconds: CaptureNormalizer.dedupBucketSeconds
                )
                let record = CapturedNotification(
                    id: observationID,
                    captureUUID: syncUUID,
                    sourceID: settings.sourceID,
                    sourceEventID: normalized.dedupKey,
                    captureChannel: normalized.channel,
                    origin: normalized.origin,
                    appLabel: normalized.appLabel,
                    title: normalized.title,
                    subtitle: normalized.subtitle,
                    body: normalized.body,
                    capturedAt: normalized.capturedAt,
                    deviceID: settings.deviceID,
                    metadataJSON: normalized.metadataJSON
                )

                let outcome: CaptureOutcome = inserted ? .captured(record) : .duplicate(record)
                try? store.recordExecutionLog(
                    appLabel: normalized.appLabel,
                    outcome: inserted ? "captured" : "duplicate",
                    detail: outcome.summaryMessage,
                    at: normalized.capturedAt
                )
                notifyChanged()
                return outcome
            } catch {
                try? store.recordExecutionLog(
                    appLabel: normalized.appLabel,
                    outcome: "failed",
                    detail: error.localizedDescription,
                    at: normalized.capturedAt
                )
                notifyChanged()
                throw error
            }
        }
    }

    // MARK: - Core Store Workflows (Shared with macOS)

    public func hybridInbox(
        scope: InboxQuery.Scope = .inbox(app: nil, saved: false),
        readFilter: InboxQuery.ReadFilter = .all,
        search: String = ""
    ) throws -> [HybridInboxItem] {
        let query = InboxQuery(scope: scope, search: search, limit: 200, readFilter: readFilter, order: .newestFirst)
        let entries = try coreStore.inbox(query)
        let provenance = try coreStore.provenanceByObservationID()
        return HybridInboxProjection.collapse(entries, provenanceByID: provenance)
    }

    public func followUps() throws -> [InboxEntry] {
        try coreStore.inbox(InboxQuery(scope: .followUps, limit: 200, order: .oldestFirst))
    }

    public func coreAppCounts() throws -> [String: Int] {
        let entries = try coreStore.inbox(InboxQuery(scope: .inbox(app: nil, saved: false), limit: 500))
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.app, default: 0] += 1
        }
        return counts
    }

    public func setRead(_ id: Int64, read: Bool) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.setRead(id, read: read)
            try coreStore.bumpWorkflowVersion(for: id, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func setFlag(_ id: Int64, flagged: Bool) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.setFlag(id, flagged: flagged)
            try coreStore.bumpWorkflowVersion(for: id, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func setSaved(_ id: Int64, saved: Bool) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.setSaved(id, saved: saved)
            try coreStore.bumpWorkflowVersion(for: id, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func scheduleFollowUp(_ id: Int64, dueAt: Double) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.schedule(id, dueAt: dueAt)
            try coreStore.bumpWorkflowVersion(for: id, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func completeFollowUp(_ id: Int64) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.complete(id)
            try coreStore.bumpWorkflowVersion(for: id, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func hideAlert(_ id: Int64) throws {
        try ingestQueue.sync {
            try coreStore.hideAlert(id)
            notifyChanged()
        }
    }

    public func restoreAlert(_ id: Int64) throws {
        try ingestQueue.sync {
            try coreStore.restoreAlert(id)
            notifyChanged()
        }
    }

    public func inboxFilters() throws -> [InboxFilter] {
        try coreStore.inboxFilters()
    }

    @discardableResult
    public func addHideRule(_ match: InboxRuleMatch) throws -> Bool {
        try ingestQueue.sync {
            let added = try coreStore.addHideRule(match)
            notifyChanged()
            return added
        }
    }

    public func setHideRuleEnabled(_ match: InboxRuleMatch, enabled: Bool) throws {
        try ingestQueue.sync {
            try coreStore.setHideRuleEnabled(match, enabled: enabled)
            notifyChanged()
        }
    }

    public func removeHideRule(_ match: InboxRuleMatch) throws {
        try ingestQueue.sync {
            try coreStore.removeHideRule(match)
            notifyChanged()
        }
    }

    public func people() throws -> [PersonRecord] {
        try coreStore.people()
    }

    @discardableResult
    public func createPerson(name: String, linking observationID: Int64? = nil) throws -> String {
        try ingestQueue.sync {
            let id = try coreStore.createPerson(name: name, linking: observationID)
            if let observationID {
                let deviceID = try store.loadOrCreateSettings().deviceID
                try coreStore.bumpWorkflowVersion(for: observationID, originDeviceID: deviceID)
            }
            notifyChanged()
            return id
        }
    }

    public func link(_ observationID: Int64, to personID: String?) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.link(observationID, to: personID)
            try coreStore.bumpWorkflowVersion(for: observationID, originDeviceID: deviceID)
            notifyChanged()
        }
    }

    public func alerts(for personID: String) throws -> [InboxEntry] {
        try coreStore.inbox(InboxQuery(scope: .person(personID), limit: 200))
    }

    public func personNotes(for personID: String) throws -> [PersonNote] {
        try coreStore.personNotes(for: personID)
    }

    public func addPersonNote(personID: String, title: String, body: String) throws {
        try ingestQueue.sync {
            _ = try coreStore.addPersonNote(person: personID, title: title, body: body, at: Date().timeIntervalSince1970)
            notifyChanged()
        }
    }

    public func deletePersonNote(_ id: String, personID: String) throws {
        try ingestQueue.sync {
            try coreStore.deletePersonNote(id, person: personID)
            notifyChanged()
        }
    }

    public func personalNotes() throws -> [PersonalNote] {
        try coreStore.personalNotes()
    }

    public func noteFolders() throws -> [NoteFolder] {
        try coreStore.noteFolders()
    }

    public func savePersonalNote(id: String? = nil, folderID: String?, title: String, body: String) throws {
        try ingestQueue.sync {
            _ = try coreStore.savePersonalNote(id, folderID: folderID, title: title, body: body, at: Date().timeIntervalSince1970)
            notifyChanged()
        }
    }

    public func deletePersonalNote(_ id: String) throws {
        try ingestQueue.sync {
            try coreStore.deletePersonalNote(id)
            notifyChanged()
        }
    }

    // MARK: - Opt-In CloudKit Sync

    public func isSyncPaired() throws -> Bool {
        let deviceID = try store.loadOrCreateSettings().deviceID
        return try coreStore.canDeviceSync(deviceID)
    }

    public func isAutoSyncEnabled() throws -> Bool {
        try coreStore.isAutoSyncEnabled()
    }

    public func setAutoSyncEnabled(_ enabled: Bool) throws {
        try ingestQueue.sync {
            try coreStore.setAutoSyncEnabled(enabled)
            notifyChanged()
        }
    }

    public func syncDevices() throws -> [SyncDeviceRecord] {
        try coreStore.syncDevices()
    }

    public func enableAndPairLocalSync(displayName: String) throws {
        try ingestQueue.sync {
            let deviceID = try store.loadOrCreateSettings().deviceID
            try coreStore.pairDevice(deviceID: deviceID, displayName: displayName, platform: .iphone)
            notifyChanged()
        }
    }

    public func revokeSyncDevice(_ deviceID: String) throws {
        try ingestQueue.sync {
            try coreStore.revokeDevice(deviceID)
            notifyChanged()
        }
    }

    public func runSync(using transport: any SyncTransport) async throws -> SyncRunResult {
        let deviceID = try settings().deviceID
        let coordinator = HybridSyncCoordinator(store: coreStore, transport: transport)
        let result = try await coordinator.syncNow(localDeviceID: deviceID)
        notifyChanged()
        return result
    }

    // MARK: - Settings & Telemetry

    public func settings() throws -> CaptureSettingsState {
        try store.loadOrCreateSettings()
    }

    public func updateSettings(_ mutate: (inout CaptureSettingsState) throws -> Void) throws -> CaptureSettingsState {
        try ingestQueue.sync {
            var state = try store.loadOrCreateSettings()
            try mutate(&state)
            try store.saveSettings(state)
            notifyChanged()
            return state
        }
    }

    public func addCustomApp(name: String) throws -> CaptureSettingsState {
        let cleaned = CaptureNormalizer.normalizeAppLabel(name)
        guard !cleaned.isEmpty else {
            throw CaptureStoreError("Enter an app name as shown in Notifications.")
        }
        return try updateSettings { state in
            if state.apps.contains(where: { $0.matches(appLabel: cleaned) }) {
                throw CaptureStoreError("\(cleaned) is already in your capture list.")
            }
            state.apps.append(
                CaptureAppConfig(
                    id: UUID().uuidString,
                    name: cleaned,
                    labels: [cleaned],
                    enabled: true,
                    isBuiltIn: false
                )
            )
        }
    }

    public func notifications(appFilter: String? = nil, searchText: String = "") throws -> [CapturedNotification] {
        let settings = try store.loadOrCreateSettings()
        let entries = try coreStore.inbox(InboxQuery(
            scope: .inbox(app: appFilter, saved: false),
            search: searchText,
            limit: 200,
            order: .newestFirst
        ))
        let provenance = try coreStore.provenanceByObservationID()
        return entries.map { entry in
            let meta = provenance[entry.id]
            let channel: CaptureChannel = meta?.channel == .manualTest ? .manualTest : .iosShortcuts
            let origin: NotificationOrigin = switch meta?.origin {
            case .iphone: .iphone
            case .mac: .mac
            default: .unknown
            }
            return CapturedNotification(
                id: entry.id,
                captureUUID: meta?.syncUUID ?? "obs-\(entry.id)",
                sourceID: meta?.sourceID ?? settings.sourceID,
                sourceEventID: "\(entry.id)",
                captureChannel: channel,
                origin: origin,
                appLabel: entry.app,
                title: entry.title,
                subtitle: entry.subtitle,
                body: entry.body,
                capturedAt: entry.capturedAt,
                deviceID: meta?.originDeviceID ?? settings.deviceID,
                metadataJSON: "{}"
            )
        }
    }

    public func stats() throws -> CaptureStats {
        let summaries = try coreStore.appSummaries()
        var total = 0
        var lastCapturedAt: Double?
        var countByApp: [String: Int] = [:]
        var lastCapturedByApp: [String: Double] = [:]
        for summary in summaries {
            total += summary.count
            countByApp[summary.appLabel] = summary.count
            lastCapturedByApp[summary.appLabel] = summary.lastCapturedAt
            if let existing = lastCapturedAt {
                lastCapturedAt = max(existing, summary.lastCapturedAt)
            } else {
                lastCapturedAt = summary.lastCapturedAt
            }
        }
        return CaptureStats(
            totalCount: total,
            lastCapturedAt: lastCapturedAt,
            countByApp: countByApp,
            lastCapturedByApp: lastCapturedByApp
        )
    }

    public func executionLogs(limit: Int = 50) throws -> [IntentExecutionLogEntry] {
        try store.fetchExecutionLogs(limit: limit)
    }

    /// Seeds synthetic sample alerts tagged `manual_test` so first-time testers
    /// and App Review can explore Inbox, Today, People, Notes, and Hide Rules
    /// without fabricating Apple Shortcuts automation verification.
    @discardableResult
    public func seedSampleAlerts(at baseDate: Date = Date()) throws -> Int {
        let samples: [IncomingNotificationPayload] = [
            IncomingNotificationPayload(
                app: "Gmail",
                title: "Priya Nair",
                subtitle: "Coffee next week?",
                body: "Are you free Thursday morning to catch up on the launch timeline?",
                receivedAt: baseDate.addingTimeInterval(-900),
                channel: .manualTest,
                sourceMetadata: ["origin_ui": "onboarding_sample"]
            ),
            IncomingNotificationPayload(
                app: "X",
                title: "Hannah Park",
                subtitle: "Direct Message",
                body: "Just sent over the notes from our run club—let me know what you think.",
                receivedAt: baseDate.addingTimeInterval(-300),
                channel: .manualTest,
                sourceMetadata: ["origin_ui": "onboarding_sample"]
            ),
            IncomingNotificationPayload(
                app: "WeChat",
                title: "Marco Rossi",
                subtitle: nil,
                body: "Tile samples arrived early, I can drop them by at 4 PM.",
                receivedAt: baseDate,
                channel: .manualTest,
                sourceMetadata: ["origin_ui": "onboarding_sample"]
            )
        ]

        var insertedCount = 0
        for sample in samples {
            if case .captured = try ingest(sample) {
                insertedCount += 1
            }
        }
        return insertedCount
    }

    public func clearAllNotifications() throws {
        try ingestQueue.sync {
            try store.clearAllNotifications()
            notifyChanged()
        }
    }

    public static let darwinChangeNotificationName = "com.notifdex.ios.captureStoreDidChange"

    private func notifyChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinChangeNotificationName as CFString),
            nil,
            nil,
            true
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .notifdexCaptureStoreDidChange, object: nil)
        }
    }
}
