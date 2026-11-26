import Foundation

public extension Notification.Name {
    static let notifdexCaptureStoreDidChange = Notification.Name("com.notifdex.ios.captureStoreDidChange")
}

/// Authoritative capture pipeline shared by `CaptureNotificationIntent` and the SwiftUI app.
/// Mirrors the invariants checked in `spec/IOSCapture.tla`.
public final class CaptureService: @unchecked Sendable {
    public static let shared: CaptureService = {
        do {
            let url = try CaptureService.defaultDatabaseURL()
            let store = try NotificationStore(databaseURL: url)
            return CaptureService(store: store)
        } catch {
            fatalError("Failed to initialize Notifdex iOS CaptureService: \(error)")
        }
    }()

    public let store: NotificationStore
    private let lock = NSLock()

    public init(store: NotificationStore) {
        self.store = store
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

    public func ingest(_ payload: IncomingNotificationPayload) throws -> CaptureOutcome {
        lock.lock()
        defer { lock.unlock() }

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
            let (record, inserted) = try store.insertNotification(
                normalized,
                sourceID: settings.sourceID,
                deviceID: settings.deviceID
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

    public func settings() throws -> CaptureSettingsState {
        lock.lock()
        defer { lock.unlock() }
        return try store.loadOrCreateSettings()
    }

    public func updateSettings(_ mutate: (inout CaptureSettingsState) throws -> Void) throws -> CaptureSettingsState {
        lock.lock()
        defer { lock.unlock() }
        var state = try store.loadOrCreateSettings()
        try mutate(&state)
        try store.saveSettings(state)
        notifyChanged()
        return state
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
        lock.lock()
        defer { lock.unlock() }
        return try store.fetchNotifications(appFilter: appFilter, searchText: searchText)
    }

    public func stats() throws -> CaptureStats {
        lock.lock()
        defer { lock.unlock() }
        return try store.stats()
    }

    public func executionLogs(limit: Int = 50) throws -> [IntentExecutionLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try store.fetchExecutionLogs(limit: limit)
    }

    public func clearAllNotifications() throws {
        lock.lock()
        defer { lock.unlock() }
        try store.clearAllNotifications()
        notifyChanged()
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
