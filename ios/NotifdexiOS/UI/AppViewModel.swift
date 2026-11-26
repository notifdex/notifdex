import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppViewModel: ObservableObject {
    @Published var notifications: [CapturedNotification] = []
    @Published var settings: CaptureSettingsState = CaptureSettingsState(deviceID: "initializing")
    @Published var stats: CaptureStats = CaptureStats()
    @Published var executionLogs: [IntentExecutionLogEntry] = []
    @Published var selectedAppFilter: String? = nil {
        didSet { reloadNotificationsOnly() }
    }
    @Published var searchText: String = "" {
        didSet { reloadNotificationsOnly() }
    }
    @Published var errorMessage: String? = nil
    @Published var toastMessage: String? = nil

    let service: CaptureService
    private var observer: NSObjectProtocol?

    init(service: CaptureService = .shared) {
        self.service = service
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .notifdexCaptureStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
            }
        }
        registerDarwinObserver()
    }

    deinit {
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

    private func registerDarwinObserver() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<AppViewModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    model.reload()
                }
            },
            CaptureService.darwinChangeNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    var availableAppsInInbox: [String] {
        let keys = stats.countByApp.keys.sorted { lhs, rhs in
            let lCount = stats.countByApp[lhs] ?? 0
            let rCount = stats.countByApp[rhs] ?? 0
            if lCount != rCount { return lCount > rCount }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return keys
    }

    var databaseFileSizeDescription: String {
        let path = service.store.databaseURL.path
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
            notifications = try service.notifications(appFilter: selectedAppFilter, searchText: searchText)
            executionLogs = try service.executionLogs(limit: 50)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadNotificationsOnly() {
        do {
            notifications = try service.notifications(appFilter: selectedAppFilter, searchText: searchText)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleApp(id: String) {
        do {
            settings = try service.updateSettings { state in
                guard let idx = state.apps.firstIndex(where: { $0.id == id }) else { return }
                state.apps[idx].enabled.toggle()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) {
        do {
            settings = try service.updateSettings { $0.paused = paused }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addCustomApp(name: String) {
        do {
            settings = try service.addCustomApp(name: name)
            toastMessage = "Added \(CaptureNormalizer.normalizeAppLabel(name)). Configure its automation in Shortcuts to begin receiving alerts."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
        do {
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
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearAllNotifications() {
        do {
            try service.clearAllNotifications()
            selectedAppFilter = nil
            toastMessage = "Cleared local captured notifications."
            reload()
        } catch {
            errorMessage = error.localizedDescription
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
}
