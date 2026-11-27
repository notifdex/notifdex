import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import UniformTypeIdentifiers
import NotifdexMac

private func smokeTrace(_ message: String) {
    if CommandLine.arguments.contains("--smoke-test") {
        print("Smoke test: \(message)")
        fflush(stdout)
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var state = AppCaptureState()
    @Published private var savingCount = 0
    @Published var uiError: String?

    var saving: Bool { savingCount > 0 }
    @Published var loginEnabled = false
    @Published var loginPending = false
    // Keep the form draft in the window's model. The standalone macOS
    // Command Line Tools may lack the SwiftUI State macro plugin.
    @Published var customLabel = ""
    @Published var showingCollectionStatus = false
    @Published var syncPaired = false
    @Published var autoSyncEnabled = true
    @Published var syncDevices: [SyncDeviceRecord] = []
    @Published var syncBusy = false
    @Published var syncMessage: String?
    @Published var syncError: String?
    @Published var lastSyncedAt: Date?
    @Published var syncDataRevision = 0
    @Published var forwardingHealth: MacForwardingHealthReport?
    private let loginQueue = DispatchQueue(label: "com.notifdex.login", qos: .utility)
    let worker: CaptureWorker
    let appearance: AppearanceSettings
    private let databaseURL: URL
    private var sleepObservers: [NSObjectProtocol] = []
    private var activeObserver: NSObjectProtocol?
    private var lastObservedCaptureAt: Date?
    private var autoSyncEngine: AutoSyncEngine?

    init() {
        let smoke = CommandLine.arguments.contains("--smoke-test")
        let directory = smoke
            ? FileManager.default.temporaryDirectory.appendingPathComponent("notifdex-smoke-" + UUID().uuidString)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notifdex")
        databaseURL = directory.appendingPathComponent("capture.db")
        worker = CaptureWorker(directory: directory)
        appearance = AppearanceSettings(directory: directory)
        if smoke {
            // Exercise real startup/storage without touching user data or navigating UI.
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var settings = CaptureSettings(sourceID: "synthetic-smoke")
                settings.paused = true
                settings.automaticRecovery = false
                try AppSettingsStore(url: directory.appendingPathComponent("settings.json")).save(settings)
            } catch { smokeTrace("fixture failed: \(error)") }
        }
        start()
        guard !smoke else { return }
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.worker.setSleeping(true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.worker.setSleeping(false)
                    self?.triggerAutoSync(.foreground)
                }
            }
        ]
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.triggerAutoSync(.foreground)
            }
        }
        setupAutoSyncEngine()
        refreshSyncState()
    }

    func start() {
        worker.start { [weak self] value in
            guard let self else { return }
            self.state = value
            if value.ready { smokeTrace("real worker ready") }
            if let savedAt = value.lastSavedAt, savedAt != self.lastObservedCaptureAt {
                self.lastObservedCaptureAt = savedAt
                self.triggerAutoSync(.localCapture)
            }
        }
    }

    func change(_ update: @escaping (inout CaptureSettings) throws -> Void, onSuccess: @escaping () -> Void = {}) {
        savingCount += 1
        worker.updateSettings(update) { [weak self] in
            guard let self else { return }
            self.savingCount = max(0, self.savingCount - 1)
            if self.state.error == nil { onSuccess() }
        }
    }

    func permission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLogin(_ enabled: Bool) {
        guard !loginPending else { return }
        loginPending = true
        loginQueue.async { [weak self] in
            var failure: String?
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { failure = "Launch at login: \(error.localizedDescription)" }
            let status = SMAppService.mainApp.status
            let message = failure ?? (status == .requiresApproval
                ? "Approve Notifdex in System Settings → General → Login Items." : nil)
            onAppMainLoop {
                self?.loginEnabled = status == .enabled
                self?.uiError = message
                self?.loginPending = false
            }
        }
    }

    func refreshLoginState() {
        guard !loginPending else { return }
        loginQueue.async { [weak self] in
            let enabled = SMAppService.mainApp.status == .enabled
            onAppMainLoop { self?.loginEnabled = enabled }
        }
    }

    var pauseBinding: Binding<Bool> {
        Binding(get: { self.state.settings?.paused ?? false },
                set: { paused in self.change { $0.paused = paused } })
    }

    var recoveryEnabled: Bool {
        state.recoveryBlocker == nil
    }

    var enabledAppCount: Int {
        state.settings?.apps.filter(\.enabled).count ?? 0
    }

    private func setupAutoSyncEngine() {
        #if canImport(CloudKit)
        let path = databaseURL.path
        autoSyncEngine = AutoSyncEngine(
            debounceSeconds: 3.0,
            baseBackoffSeconds: 15.0,
            maxBackoffSeconds: 300.0,
            maxFailureStreak: 5,
            periodicIntervalSeconds: 45.0,
            syncAction: {
                let store = try CaptureStore(path: path)
                let deviceID = try store.localSyncDeviceID()
                let coordinator = HybridSyncCoordinator(store: store, transport: CloudKitSyncTransport())
                return try await coordinator.syncNow(localDeviceID: deviceID)
            },
            onSyncCompleted: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.lastSyncedAt = Date(timeIntervalSince1970: result.syncedAt)
                    self.syncError = nil
                    if result.pushedObservations > 0 || result.applied.hasChanges {
                        self.syncMessage = "Synced: pushed \(result.pushedObservations) alerts, pulled \(result.applied.insertedObservations) new."
                    } else {
                        self.syncMessage = "Up to date with iCloud."
                    }
                    if result.applied.hasChanges {
                        self.syncDataRevision += 1
                    }
                    self.refreshSyncMetadataOnly()
                }
            },
            onSyncFailed: { [weak self] error in
                Task { @MainActor in
                    self?.syncError = "CloudKit sync: \(error.localizedDescription)"
                }
            },
            onPhaseChanged: { [weak self] phase in
                Task { @MainActor in
                    self?.syncBusy = (phase == .running)
                }
            }
        )
        #endif
    }

    func notifyLocalWorkflowChanged() {
        triggerAutoSync(.localEdit)
    }

    func triggerAutoSync(_ reason: AutoSyncTrigger) {
        guard let engine = autoSyncEngine else { return }
        Task {
            await engine.trigger(reason)
        }
    }

    private func configureAutoSync(paired: Bool, autoEnabled: Bool) {
        #if canImport(CloudKit)
        let entitled = CloudKitSyncTransport().hasCloudKitEntitlement()
        let effectiveAuto = paired && autoEnabled && entitled
        if let engine = autoSyncEngine {
            Task {
                await engine.configure(paired: paired, autoEnabled: effectiveAuto)
            }
        }
        if effectiveAuto {
            Task {
                try? await CloudKitSyncTransport().ensureDatabaseSubscription()
            }
        }
        #endif
    }

    private func refreshSyncMetadataOnly() {
        let path = databaseURL.path
        let enabledApps = state.settings?.allowedLabels ?? []
        loginQueue.async { [weak self] in
            do {
                let store = try CaptureStore(path: path)
                let deviceID = try store.localSyncDeviceID()
                let devices = try store.syncDevices()
                let health = try store.macForwardingHealth(localDeviceID: deviceID, enabledApps: enabledApps)
                onAppMainLoop {
                    self?.syncDevices = devices
                    self?.forwardingHealth = health
                }
            } catch {
                onAppMainLoop { self?.syncError = error.localizedDescription }
            }
        }
    }

    func refreshSyncState() {
        let path = databaseURL.path
        let enabledApps = state.settings?.allowedLabels ?? []
        loginQueue.async { [weak self] in
            do {
                let store = try CaptureStore(path: path)
                let deviceID = try store.localSyncDeviceID()
                let paired = try store.canDeviceSync(deviceID)
                let autoEnabled = try store.isAutoSyncEnabled()
                let devices = try store.syncDevices()
                let health = try store.macForwardingHealth(localDeviceID: deviceID, enabledApps: enabledApps)
                onAppMainLoop {
                    self?.syncPaired = paired
                    self?.autoSyncEnabled = autoEnabled
                    self?.syncDevices = devices
                    self?.forwardingHealth = health
                    self?.configureAutoSync(paired: paired, autoEnabled: autoEnabled)
                }
            } catch {
                onAppMainLoop { self?.syncError = error.localizedDescription }
            }
        }
    }

    func setAutoSyncEnabled(_ enabled: Bool) {
        let path = databaseURL.path
        loginQueue.async { [weak self] in
            do {
                let store = try CaptureStore(path: path)
                try store.setAutoSyncEnabled(enabled)
                let deviceID = try store.localSyncDeviceID()
                let paired = try store.canDeviceSync(deviceID)
                onAppMainLoop {
                    self?.autoSyncEnabled = enabled
                    self?.configureAutoSync(paired: paired, autoEnabled: enabled)
                }
            } catch {
                onAppMainLoop { self?.syncError = error.localizedDescription }
            }
        }
    }

    func enableCloudKitSync() {
        let path = databaseURL.path
        let hostName = Host.current().localizedName ?? "Mac"
        loginQueue.async { [weak self] in
            do {
                let store = try CaptureStore(path: path)
                let deviceID = try store.localSyncDeviceID()
                try store.pairDevice(deviceID: deviceID, displayName: hostName, platform: .mac)
                let autoEnabled = try store.isAutoSyncEnabled()
                let devices = try store.syncDevices()
                onAppMainLoop {
                    self?.syncPaired = true
                    self?.autoSyncEnabled = autoEnabled
                    self?.syncDevices = devices
                    self?.syncError = nil
                    self?.syncMessage = "Mac paired for opt-in iCloud Sync."
                    self?.configureAutoSync(paired: true, autoEnabled: autoEnabled)
                }
            } catch {
                onAppMainLoop { self?.syncError = error.localizedDescription }
            }
        }
    }

    func revokeSyncDevice(_ deviceID: String) {
        let path = databaseURL.path
        loginQueue.async { [weak self] in
            do {
                let store = try CaptureStore(path: path)
                try store.revokeDevice(deviceID)
                let localID = try store.localSyncDeviceID()
                let paired = try store.canDeviceSync(localID)
                let autoEnabled = try store.isAutoSyncEnabled()
                let devices = try store.syncDevices()
                onAppMainLoop {
                    self?.syncPaired = paired
                    self?.syncDevices = devices
                    self?.syncError = nil
                    self?.syncMessage = "Device revoked. Local observations remain intact."
                    self?.configureAutoSync(paired: paired, autoEnabled: autoEnabled)
                }
            } catch {
                onAppMainLoop { self?.syncError = error.localizedDescription }
            }
        }
    }

    func syncNowWithCloudKit() {
        #if canImport(CloudKit)
        syncError = nil
        if let engine = autoSyncEngine {
            Task {
                await engine.trigger(.manual)
            }
            return
        }
        guard !syncBusy else { return }
        syncBusy = true
        let path = databaseURL.path
        let enabledApps = state.settings?.allowedLabels ?? []
        Task {
            defer {
                Task { @MainActor in self.syncBusy = false }
            }
            do {
                let store = try CaptureStore(path: path)
                let deviceID = try store.localSyncDeviceID()
                let coordinator = HybridSyncCoordinator(store: store, transport: CloudKitSyncTransport())
                let result = try await coordinator.syncNow(localDeviceID: deviceID)
                let devices = try store.syncDevices()
                let health = try store.macForwardingHealth(localDeviceID: deviceID, enabledApps: enabledApps)
                await MainActor.run {
                    self.syncDevices = devices
                    self.forwardingHealth = health
                    self.lastSyncedAt = Date(timeIntervalSince1970: result.syncedAt)
                    self.syncMessage = "Synced: pushed \(result.pushedObservations) alerts, pulled \(result.applied.insertedObservations) new."
                    self.syncError = nil
                    if result.applied.hasChanges {
                        self.syncDataRevision += 1
                    }
                }
            } catch {
                await MainActor.run {
                    self.syncError = "CloudKit sync: \(error.localizedDescription)"
                }
            }
        }
        #else
        syncError = "CloudKit is unavailable in this build."
        #endif
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var appCenterController: AppCenterWindowController?

    func showAppCenter() {
        NSApp.setActivationPolicy(.regular)
        let controller = appCenterController ?? AppCenterWindowController(
            model: AppModel.shared,
            appearance: AppModel.shared.appearance
        )
        appCenterController = controller
        controller.showAppCenter()
    }

    private func ensureCloseWindowShortcut() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let hasCloseShortcut = mainMenu.items.contains { topItem in
            topItem.submenu?.items.contains {
                $0.keyEquivalent.lowercased() == "w" && $0.action == #selector(NSWindow.performClose(_:))
            } ?? false
        }
        guard !hasCloseShortcut else { return }

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let closeItem = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu

        let insertIndex = min(1, mainMenu.items.count)
        mainMenu.insertItem(fileMenuItem, at: insertIndex)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        smokeTrace("application did finish launching")
        AppIconCatalog.applyDockIcon()
        ensureCloseWindowShortcut()
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.setActivationPolicy(.accessory)
                self.showAppCenter()
                if NSApp.activationPolicy() == .regular { smokeTrace("window entered app switcher") }
                self.appCenterController?.window?.close()
                if NSApp.activationPolicy() == .accessory { smokeTrace("closed window returned to menu bar") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showAppCenter()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !CommandLine.arguments.contains("--smoke-test") else { return false }
        showAppCenter()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        smokeTrace("application requested shutdown")
        AppModel.shared.worker.stop {
            smokeTrace("worker stopped")
            if CommandLine.arguments.contains("--smoke-test") {
                try? FileManager.default.removeItem(at: AppModel.shared.worker.directory)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
struct NotifdexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @StateObject private var appearance: AppearanceSettings

    init() {
        smokeTrace("constructing SwiftUI app")
        _model = StateObject(wrappedValue: AppModel.shared)
        _appearance = StateObject(wrappedValue: AppModel.shared.appearance)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: AppIconCatalog.menuBarImage(style: appearance.menuBarIconStyle))
                .renderingMode(appearance.menuBarIconStyle == .monochrome ? .template : .original)
        }
    }

    fileprivate static func checkPackage() throws {
        guard Bundle.main.url(forResource: "schema", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged schema.sql is missing")
        }
        guard Bundle.main.url(forResource: "inbox-work", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged inbox-work.sql is missing")
        }
        guard Bundle.main.url(forResource: "filters", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged filters.sql is missing")
        }
        guard Bundle.main.url(forResource: "person-matches", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged person-matches.sql is missing")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard Bundle.main.url(forResource: "person-notes", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged person-notes.sql is missing")
        }
        guard Bundle.main.url(forResource: "flags", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged flags.sql is missing")
        }
        guard Bundle.main.url(forResource: "hide-rules", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged hide-rules.sql is missing")
        }
        let store = try CaptureStore(path: directory.appendingPathComponent("self-check.db").path)
        let run = try store.startRun(at: 1)
        let observation = Observation(sourceID: "synthetic", sourceEventID: "1", capturedAt: 2,
                                      description: "X, Example, Test, from iPhone", title: "Example", body: "Test")
        _ = try store.record(observation, runID: run)
        guard try !store.record(observation, runID: run), try store.observationCount() == 1 else {
            throw StoreError(description: "Packaged replay check failed")
        }
        guard let alert = try store.inbox(InboxQuery()).first else {
            throw StoreError(description: "Packaged inbox check failed")
        }
        let person = try store.createPerson(name: "Example", linking: alert.id)
        try store.setSaved(alert.id, saved: true)
        try store.schedule(alert.id, dueAt: 3)
        guard try store.inbox(InboxQuery(scope: .followUps)).first?.personID == person else {
            throw StoreError(description: "Packaged follow-up check failed")
        }
        try store.hideAlert(alert.id)
        guard try store.inbox(InboxQuery()).isEmpty,
              try store.inbox(InboxQuery(scope: .hidden(app: nil))).first?.id == alert.id else {
            throw StoreError(description: "Packaged Inbox filter check failed")
        }
        try store.restoreAlert(alert.id)
        let match = try store.previewPersonMatch(for: alert.id)
        try store.confirmPersonMatch(match, includeExisting: true)
        guard try store.personMatchRules(for: person).count == 1 else {
            throw StoreError(description: "Packaged person match check failed")
        }
        let note = try store.addPersonNote(person: person, body: "Synthetic note", at: 3)
        guard try store.personNotes(for: person).first?.id == note else {
            throw StoreError(description: "Packaged person notes check failed")
        }
        let folder = try store.saveNoteFolder(name: "Synthetic folder")
        let personalNote = try store.savePersonalNote(folderID: folder, title: "Test", body: "Synthetic personal note", at: 3)
        try store.deleteNoteFolder(folder)
        guard let unfiled = try store.personalNotes().first, unfiled.id == personalNote, unfiled.folderID == nil else {
            throw StoreError(description: "Packaged notebook check failed")
        }
        guard Bundle.main.url(forResource: "notebook", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged notebook.sql is missing")
        }
        try store.setFlag(alert.id, flagged: true)
        guard try store.inbox(InboxQuery(scope: .flagged(app: nil))).first?.id == alert.id else {
            throw StoreError(description: "Packaged Flagged check failed")
        }
        let titleRule = InboxRuleMatch(app: alert.app, field: .title, text: alert.title)
        guard try store.previewHideRule(titleRule) == 1, try store.addHideRule(titleRule),
              try store.inbox(InboxQuery(scope: .flagged(app: nil))).isEmpty else {
            throw StoreError(description: "Packaged title hide check failed")
        }
        try store.removeHideRule(titleRule)
        guard try store.inbox(InboxQuery(scope: .flagged(app: nil))).first?.id == alert.id else {
            throw StoreError(description: "Packaged hide-rule undo check failed")
        }
        guard Bundle.main.url(forResource: "relationship-templates", withExtension: "sql") != nil,
              Bundle.main.url(forResource: "founder-outreach-v1", withExtension: "json", subdirectory: "templates") != nil else {
            throw StoreError(description: "Packaged relationship template resources are missing")
        }
        let template = try store.installTemplate(RelationshipTemplate.bundledFounderOutreach())
        try store.applyTemplate(template, to: person)
        try store.setTemplateStage("evaluating", for: person)
        try store.setTemplateMilestone("joined-slack", completed: true, for: person)
        let replay = try store.applyTemplate(template, to: person)
        guard replay.stageID == "evaluating", replay.completedMilestones == ["joined-slack"] else {
            throw StoreError(description: "Packaged relationship template replay check failed")
        }
        guard Bundle.main.url(forResource: "workspaces", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged workspaces.sql is missing")
        }
        let workspace = try store.createWorkspace(name: "Example workspace")
        try store.setWorkspaceMembership(person: person, workspace: workspace, isMember: true)
        try store.setAlertWorkspace(alert.id, to: workspace)
        guard try store.people(in: workspace).map(\.id) == [person],
              try store.inbox(InboxQuery(scope: .person(person), workspaceID: workspace)).map(\.id) == [alert.id] else {
            throw StoreError(description: "Packaged workspace scope check failed")
        }
        try store.finishRun(runID: run, at: 3)
    }
}

@main
@MainActor
struct NotifdexLauncher {
    static func main() {
        // Validate the bundle before SwiftUI starts an application session.
        if CommandLine.arguments.contains("--self-check") {
            do {
                try NotifdexApp.checkPackage()
                print("Packaged SQLite resources and replay check passed.")
                exit(0)
            } catch {
                fputs("Package check failed: \(error)\n", stderr)
                exit(1)
            }
        }
        smokeTrace("starting SwiftUI lifecycle")
        NotifdexApp.main()
    }
}

@MainActor
struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.state.status)
        Text("\(model.state.total) saved observations")
        Divider()
        Button("App Center…") {
            AppDelegate.shared?.showAppCenter()
        }
        Toggle("Pause collection", isOn: model.pauseBinding)
            .disabled(!model.state.ready || model.saving)
        Button("Recover retained notifications") { model.worker.recoverNow() }
            .disabled(!model.recoveryEnabled)
        if !model.state.permissionGranted {
            Button("Grant Accessibility access…") { model.permission() }
        }
        Divider()
        Button("Quit Notifdex") { NSApp.terminate(nil) }
    }
}

@MainActor
struct AppCenter: View {
    @ObservedObject var model: AppModel
    @ObservedObject var appearance: AppearanceSettings

    private var config: AppearanceConfiguration {
        appearance.activeConfiguration
    }

    var body: some View {
        WorkflowView(
            appModel: model,
            appearance: appearance,
            worker: model.worker,
            ready: model.state.ready,
            total: model.state.total,
            apps: model.state.summaries.map(\.appLabel),
            appsView: { appsView },
            recoveryView: { recoveryView }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.notifdexAppearanceConfig, config)
        .fileImporter(isPresented: $appearance.showingBackdropImporter, allowedContentTypes: [.image]) { result in
            appearance.importBackdrop(result)
        }
    }

    private var appsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            List(model.state.settings?.apps ?? []) { app in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.system(size: 13.5, weight: .medium))
                        let summaries = model.state.summaries.filter { app.labels.contains($0.appLabel) }
                        let count = summaries.reduce(0) { $0 + $1.count }
                        HStack(spacing: 6) {
                            Text(count == 0 ? "Awaiting first alert" : "\(count) saved")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let last = summaries.map(\.lastCapturedAt).max() {
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(Date(timeIntervalSince1970: last), style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    Toggle(app.name, isOn: Binding(
                        get: { app.enabled },
                        set: { enabled in
                            model.change { settings in
                                if let index = settings.apps.firstIndex(where: { $0.id == app.id }) {
                                    settings.apps[index].enabled = enabled
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.state.ready || model.saving)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            .notifdexSurface(.list)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    TextField("Custom app notification label", text: $model.customLabel)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.14))
                                .frame(height: 0.5)
                        }

                    Button("Add app") {
                        let label = model.customLabel
                        model.change({ try $0.addCustomApp(label: label) }) {
                            model.customLabel = ""
                        }
                    }
                    .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                    .disabled(model.customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.state.ready || model.saving)
                }
                Text("App labels must match notifications as shown by macOS. Enable each app you want to collect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    private var recoveryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Retained notifications")
                                .font(.system(size: 16, weight: .regular, design: .serif))
                            Text("Opens Notification Center, expands selected app stacks, and scrolls retained alerts. May briefly interrupt your screen.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        Button(model.state.recovering ? "Recovering…" : "Recover now") {
                            model.worker.recoverNow()
                        }
                        .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        .disabled(!model.recoveryEnabled)
                    }

                    Toggle("Recover on launch, wake, and app selection changes", isOn: Binding(
                        get: { model.state.settings?.automaticRecovery ?? false },
                        set: { enabled in model.change { $0.automaticRecovery = enabled } }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!model.state.ready || model.saving)

                    if let recoveryError = model.state.recoveryError {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recoveryError)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Text("Live capture is still running. Open Notification Center manually or click Recover now to retry.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .notifdexSurface(.card)
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Diagnostics")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                    LabeledContent("Recovery status") {
                        Text(model.state.recoveryStatus)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let blocker = model.state.recoveryBlocker {
                        LabeledContent("Blocker") {
                            Text(blocker)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let saved = model.state.lastSavedAt {
                        LabeledContent("Last new capture this session") {
                            Text(saved.formatted(date: .abbreviated, time: .standard))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let issue = model.state.lastCaptureIssue {
                        LabeledContent("Last scan issue") {
                            Text(issue)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Text("Cleared, hidden, or undelivered alerts may be unavailable. A completed scan leaves delivery coverage unknown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("iOS & iCloud Sync")
                                .font(.system(size: 16, weight: .regular, design: .serif))
                            Text("Opt-in private CloudKit sync between macOS and Notifdex iOS. Hidden alerts stay local and never sync.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 16)
                        if !model.syncPaired {
                            Button("Enable & Pair") {
                                model.enableCloudKitSync()
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                        } else {
                            Button(model.syncBusy ? "Syncing…" : "Sync Now") {
                                model.syncNowWithCloudKit()
                            }
                            .buttonStyle(NotifdexGlassButtonStyle(emphasis: .prominent))
                            .disabled(model.syncBusy)
                        }
                    }

                    LabeledContent("Sync status") {
                        Text(model.syncPaired ? (model.autoSyncEnabled ? "Paired · Auto-sync on" : "Paired · Manual only") : "Local-only")
                            .foregroundStyle(.secondary)
                    }
                    if model.syncPaired {
                        Toggle("Automatic iCloud Sync", isOn: Binding(
                            get: { model.autoSyncEnabled },
                            set: { enabled in model.setAutoSyncEnabled(enabled) }
                        ))
                        .toggleStyle(.switch)
                        if let lastSyncedAt = model.lastSyncedAt {
                            LabeledContent("Last synced") {
                                Text(lastSyncedAt.formatted(date: .omitted, time: .standard))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let syncMessage = model.syncMessage {
                        Text(syncMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let syncError = model.syncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if let health = model.forwardingHealth, health.status == .degraded {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(health.summary, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                            if let hint = health.remediationHint {
                                Text(hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .notifdexSurface(.card)
                    }
                    ForEach(model.syncDevices) { device in
                        HStack {
                            Text("\(device.displayName) (\(device.platform.displayLabel) · \(device.status.rawValue))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if device.status == .paired {
                                Button("Revoke") {
                                    model.revokeSyncDevice(device.deviceID)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5)

                VStack(alignment: .leading, spacing: 10) {
                    Text("System")
                        .font(.system(size: 16, weight: .regular, design: .serif))
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.loginEnabled },
                        set: { enabled in model.setLogin(enabled) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(model.loginPending)
                    if model.loginPending {
                        Text("Updating login item…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Saved source identity") {
                        Text(model.state.settings?.sourceID ?? "pending")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.top, 4)
        }
        .onAppear {
            model.refreshLoginState()
            model.refreshSyncState()
        }
    }
}
#else
@main
struct NotifdexApp {
    static func main() { print("The Notifdex menu bar app requires macOS.") }
}
#endif
