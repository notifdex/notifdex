import Foundation
import NotifdexCore
import SwiftUI
import UIKit

enum InboxTabFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unread = "Unread"
    case flagged = "Flagged"
    case saved = "Saved"

    var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var hybridItems: [HybridInboxItem] = []
    @Published var followUps: [InboxEntry] = []
    @Published var people: [PersonRecord] = []
    @Published var personalNotes: [PersonalNote] = []
    @Published var noteFolders: [NoteFolder] = []
    @Published var coreAppCounts: [String: Int] = [:]

    @Published var settings: CaptureSettingsState = CaptureSettingsState(deviceID: "initializing")
    @Published var stats: CaptureStats = CaptureStats()
    @Published var executionLogs: [IntentExecutionLogEntry] = []

    @Published var inboxFilter: InboxTabFilter = .all {
        didSet { reloadInboxOnly() }
    }
    @Published var selectedAppFilter: String? = nil {
        didSet { reloadInboxOnly() }
    }
    @Published var searchText: String = "" {
        didSet { reloadInboxOnly() }
    }

    @Published var isSyncPaired: Bool = false
    @Published var syncDevices: [SyncDeviceRecord] = []
    @Published var isSyncing: Bool = false
    @Published var lastSyncSummary: String? = nil

    @Published var errorMessage: String? = nil
    @Published var toastMessage: String? = nil

    let service: CaptureService
    private var observer: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    init(service: CaptureService = .shared) {
        self.service = service
        if UIApplication.shared.applicationState == .active {
            reload()
        }
        observer = NotificationCenter.default.addObserver(
            forName: .notifdexCaptureStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleForegroundReload()
            }
        }
        registerDarwinObserver()
    }

    deinit {
        reloadTask?.cancel()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(CaptureService.darwinChangeNotificationName as CFString),
            nil
        )
    }

    private func scheduleForegroundReload() {
        // Never run 11 UI SQLite queries while backgrounded during Shortcuts execution.
        guard UIApplication.shared.applicationState == .active else { return }
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            self?.reload()
        }
    }

    private func registerDarwinObserver() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<AppViewModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    model.scheduleForegroundReload()
                }
            },
            CaptureService.darwinChangeNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    var availableAppsInInbox: [String] {
        coreAppCounts.keys.sorted { lhs, rhs in
            let lCount = coreAppCounts[lhs] ?? 0
            let rCount = coreAppCounts[rhs] ?? 0
            if lCount != rCount { return lCount > rCount }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    var databaseFileSizeDescription: String {
        let path = (try? CaptureService.defaultCoreDatabaseURL().path) ?? service.store.databaseURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return "Not created yet"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func reload() {
        do {
            settings = try service.settings()
            stats = try service.stats()
            coreAppCounts = try service.coreAppCounts()
            followUps = try service.followUps()
            people = try service.people()
            personalNotes = try service.personalNotes()
            noteFolders = try service.noteFolders()
            executionLogs = try service.executionLogs(limit: 50)
            isSyncPaired = try service.isSyncPaired()
            syncDevices = try service.syncDevices()
            reloadInboxOnly()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadInboxOnly() {
        do {
            let scope: InboxQuery.Scope
            let readFilter: InboxQuery.ReadFilter
            switch inboxFilter {
            case .all:
                scope = .inbox(app: selectedAppFilter, saved: false)
                readFilter = .all
            case .unread:
                scope = .inbox(app: selectedAppFilter, saved: false)
                readFilter = .unread
            case .flagged:
                scope = .flagged(app: selectedAppFilter)
                readFilter = .all
            case .saved:
                scope = .inbox(app: selectedAppFilter, saved: true)
                readFilter = .all
            }
            hybridItems = try service.hybridInbox(scope: scope, readFilter: readFilter, search: searchText)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Workflow Actions

    func toggleRead(_ entry: InboxEntry) {
        performAction { try service.setRead(entry.id, read: !entry.isRead) }
    }

    func toggleFlag(_ entry: InboxEntry) {
        performAction { try service.setFlag(entry.id, flagged: !entry.isFlagged) }
    }

    func toggleSaved(_ entry: InboxEntry) {
        performAction { try service.setSaved(entry.id, saved: !entry.saved) }
    }

    func scheduleFollowUp(_ entry: InboxEntry, dueDate: Date) {
        performAction(toast: "Follow-up scheduled.") {
            try service.scheduleFollowUp(entry.id, dueAt: dueDate.timeIntervalSince1970)
        }
    }

    func completeFollowUp(_ entry: InboxEntry) {
        performAction(toast: "Follow-up completed.") {
            try service.completeFollowUp(entry.id)
        }
    }

    func hideAlert(_ entry: InboxEntry) {
        performAction(toast: "Alert hidden.") {
            try service.hideAlert(entry.id)
        }
    }

    func createPerson(name: String, linking observationID: Int64? = nil) {
        performAction(toast: "Saved \(name).") {
            _ = try service.createPerson(name: name, linking: observationID)
        }
    }

    func link(_ observationID: Int64, to personID: String?) {
        performAction {
            try service.link(observationID, to: personID)
        }
    }

    func alerts(for personID: String) -> [InboxEntry] {
        (try? service.alerts(for: personID)) ?? []
    }

    func personNotes(for personID: String) -> [PersonNote] {
        (try? service.personNotes(for: personID)) ?? []
    }

    func addPersonNote(personID: String, title: String, body: String) {
        performAction(toast: "Added note.") {
            try service.addPersonNote(personID: personID, title: title, body: body)
        }
    }

    func deletePersonNote(_ id: String, personID: String) {
        performAction {
            try service.deletePersonNote(id, personID: personID)
        }
    }

    func savePersonalNote(id: String? = nil, folderID: String?, title: String, body: String) {
        performAction(toast: "Note saved.") {
            try service.savePersonalNote(id: id, folderID: folderID, title: title, body: body)
        }
    }

    func deletePersonalNote(_ id: String) {
        performAction {
            try service.deletePersonalNote(id)
        }
    }

    // MARK: - Capture & Sync Actions

    func toggleApp(id: String) {
        performAction {
            settings = try service.updateSettings { state in
                guard let idx = state.apps.firstIndex(where: { $0.id == id }) else { return }
                state.apps[idx].enabled.toggle()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        performAction {
            settings = try service.updateSettings { $0.paused = paused }
        }
    }

    func addCustomApp(name: String) {
        performAction(toast: "Added \(CaptureNormalizer.normalizeAppLabel(name)).") {
            settings = try service.addCustomApp(name: name)
        }
    }

    func enableCloudKitSync() {
        performAction(toast: "iPhone paired for opt-in iCloud Sync.") {
            try service.enableAndPairLocalSync(displayName: UIDevice.current.name)
        }
    }

    func revokeSyncDevice(_ deviceID: String) {
        performAction(toast: "Device revoked from sync. Local data preserved.") {
            try service.revokeSyncDevice(deviceID)
        }
    }

    func syncNowWithCloudKit() {
        #if canImport(CloudKit)
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        Task {
            defer { isSyncing = false }
            do {
                let transport = CloudKitSyncTransport()
                let result = try await service.runSync(using: transport)
                lastSyncSummary = "Pushed \(result.pushedObservations) alerts · Pulled \(result.applied.insertedObservations) new"
                toastMessage = lastSyncSummary
                reload()
            } catch {
                errorMessage = "CloudKit sync: \(error.localizedDescription)"
            }
        }
        #else
        errorMessage = "CloudKit is unavailable in this build."
        #endif
    }

    func automationStatus(for app: CaptureAppConfig) -> AppAutomationStatus {
        let matchingCount = stats.countByApp.reduce(0) { partial, entry in
            app.matches(appLabel: entry.key) ? partial + entry.value : partial
        }
        let latestCapture = stats.lastCapturedByApp.reduce(nil as Double?) { current, entry in
            guard app.matches(appLabel: entry.key) else { return current }
            guard let current else { return entry.value }
            return max(current, entry.value)
        }

        if !app.enabled {
            return .paused(count: matchingCount)
        }
        if settings.isVerified(app: app) {
            return .active(lastCapturedAt: latestCapture ?? 0, count: matchingCount)
        }
        return .awaitingShortcut
    }

    func simulateTestCapture(app: String, title: String, subtitle: String?, body: String) {
        performAction {
            let payload = IncomingNotificationPayload(
                app: app,
                title: title,
                subtitle: subtitle,
                body: body,
                receivedAt: Date(),
                channel: .manualTest,
                sourceMetadata: ["origin_ui": "settings_simulator"]
            )
            let outcome = try service.ingest(payload)
            toastMessage = outcome.summaryMessage
        }
    }

    func clearAllNotifications() {
        performAction(toast: "Cleared Phase 1 telemetry store.") {
            try service.clearAllNotifications()
            selectedAppFilter = nil
        }
    }

    func openShortcutsAutomations() {
        let candidates = [
            URL(string: "shortcuts://automations"),
            URL(string: "shortcuts://")
        ].compactMap { $0 }

        for url in candidates {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
        errorMessage = "Could not open Apple Shortcuts. Open the Shortcuts app manually and tap Automation."
    }

    private func performAction(toast: String? = nil, _ work: () throws -> Void) {
        do {
            try work()
            if let toast { toastMessage = toast }
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
