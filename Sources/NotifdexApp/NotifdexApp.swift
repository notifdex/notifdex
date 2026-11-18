import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
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
    @Published var saving = false
    @Published var uiError: String?
    @Published var loginEnabled = false
    @Published var loginPending = false
    // Keep the form draft in the window's model. The standalone macOS
    // Command Line Tools may lack the SwiftUI State macro plugin.
    @Published var customLabel = ""
    private let loginQueue = DispatchQueue(label: "com.notifdex.login", qos: .utility)
    let worker: CaptureWorker
    private var sleepObservers: [NSObjectProtocol] = []

    init() {
        let smoke = CommandLine.arguments.contains("--smoke-test")
        let directory = smoke
            ? FileManager.default.temporaryDirectory.appendingPathComponent("notifdex-smoke-" + UUID().uuidString)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Notifdex")
        worker = CaptureWorker(directory: directory)
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
                Task { @MainActor in self?.worker.setSleeping(false) }
            }
        ]
    }

    func start() {
        worker.start { [weak self] value in
            self?.state = value
            if value.ready { smokeTrace("real worker ready") }
        }
    }

    func change(_ update: @escaping (inout CaptureSettings) throws -> Void) {
        saving = true
        worker.updateSettings(update) { [weak self] in self?.saving = false }
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
        state.ready && state.permissionGranted && !(state.settings?.paused ?? true)
            && !(state.settings?.allowedLabels.isEmpty ?? true) && !state.recovering
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        smokeTrace("application did finish launching")
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        }
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

    init() {
        smokeTrace("constructing SwiftUI app")
        _model = StateObject(wrappedValue: AppModel.shared)
    }

    var body: some Scene {
        MenuBarExtra("Notifdex", systemImage: "tray.full") {
            MenuContent(model: model)
        }
        Window("Notifdex · App Center", id: "app-center") {
            AppCenter(model: model)
        }
        .defaultSize(width: 780, height: 620)
    }

    fileprivate static func checkPackage() throws {
        guard Bundle.main.url(forResource: "schema", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged schema.sql is missing")
        }
        guard Bundle.main.url(forResource: "rolodex", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged rolodex.sql is missing")
        }
        guard Bundle.main.url(forResource: "filters", withExtension: "sql") != nil else {
            throw StoreError(description: "Packaged filters.sql is missing")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.state.status)
        Text("\(model.state.total) saved observations")
        Divider()
        Button("App Center…") {
            openWindow(id: "app-center")
            NSApp.activate(ignoringOtherApps: true)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.state.status).font(.headline)
                    Text(model.state.lastScan).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Paused", isOn: model.pauseBinding)
                    .toggleStyle(.switch)
                    .disabled(!model.state.ready || model.saving)
            }
            if let message = model.uiError ?? model.state.error {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }
            if !model.state.ready {
                Button("Retry starting capture") { model.start() }
            } else if !model.state.permissionGranted {
                HStack {
                    Text("Allow Notifdex in Privacy & Security → Accessibility.")
                    Spacer()
                    Button("Open Accessibility Settings") { model.permission() }
                }
            }
            TabView {
                WorkflowView(worker: model.worker, ready: model.state.ready,
                             total: model.state.total, apps: model.state.summaries.map(\.appLabel))
                    .tabItem { Label("Inbox", systemImage: "tray") }
                appsView.tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                recoveryView.tabItem { Label("Recovery", systemImage: "arrow.clockwise") }
            }
            HStack {
                Text("\(model.state.total) saved observations").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Show data folder") {
                    NSWorkspace.shared.open(model.worker.directory)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 660, minHeight: 520)
    }

    private var appsView: some View {
        VStack(spacing: 10) {
            List(model.state.settings?.apps ?? []) { app in
                HStack {
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
                    .toggleStyle(.switch)
                    .disabled(!model.state.ready || model.saving)
                    Spacer()
                    let summaries = model.state.summaries.filter { app.labels.contains($0.appLabel) }
                    let count = summaries.reduce(0) { $0 + $1.count }
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(count == 0 ? "Awaiting first alert" : "\(count) saved")
                        if let last = summaries.map(\.lastCapturedAt).max() {
                            Text(Date(timeIntervalSince1970: last), style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            HStack {
                TextField("Custom app notification label", text: $model.customLabel)
                    .textFieldStyle(.roundedBorder)
                Button("Add app") {
                    let label = model.customLabel
                    model.change { try $0.addCustomApp(label: label) }
                    model.customLabel = ""
                }
                .disabled(model.customLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.state.ready)
            }
            Text("App labels must match notifications as shown by macOS. Enable each app you want to collect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }

    private var recoveryView: some View {
        Form {
            Toggle("Recover on launch, wake, and app selection changes", isOn: Binding(
                get: { model.state.settings?.automaticRecovery ?? false },
                set: { enabled in model.change { $0.automaticRecovery = enabled } }
            ))
            .disabled(!model.state.ready || model.saving)
            Text("Recovery opens Notification Center, expands selected app stacks, and attempts to scroll retained alerts. It can briefly interrupt your current screen.")
                .foregroundStyle(.secondary)
            HStack {
                Button(model.state.recovering ? "Recovering…" : "Recover now") { model.worker.recoverNow() }
                    .disabled(!model.recoveryEnabled)
                Text(model.state.recoveryStatus).textSelection(.enabled)
            }
            Text("Cleared, hidden, or undelivered alerts may be unavailable. A completed scan leaves delivery coverage unknown.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: { enabled in model.setLogin(enabled) }))
                .disabled(model.loginPending)
            if model.loginPending { Text("Updating login item…").font(.caption) }
            Text("Saved source identity: \(model.state.settings?.sourceID ?? "pending")")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(16)
        .onAppear { model.refreshLoginState() }
    }
}
#else
@main
struct NotifdexApp {
    static func main() { print("The Notifdex menu bar app requires macOS.") }
}
#endif
