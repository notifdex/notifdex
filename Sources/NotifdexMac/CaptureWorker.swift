import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import ApplicationServices
import Darwin

public struct AppCaptureState {
    public var settings: CaptureSettings?
    public var permissionGranted = false
    public var ready = false
    public var recovering = false
    public var sleeping = false
    public var screenLocked = false
    public var status = "Starting capture"
    public var recoveryStatus = "No recovery run yet"
    public var lastScan = "No scan yet"
    public var lastCaptureIssue: String?
    public var lastSavedAt: Date?
    public var recent: [StoredObservation] = []
    public var summaries: [AppCaptureSummary] = []
    public var total = 0
    public var error: String?
    public var recoveryError: String?
    public init() {}

    public var recoveryBlocker: String? {
        if !ready { return error ?? "Waiting for the capture database to open." }
        if sleeping { return "Recovery can run when this Mac wakes." }
        if screenLocked { return "Recovery will run automatically when this Mac unlocks." }
        if settings?.paused != false { return "Resume capture to recover alerts." }
        if settings?.allowedLabels.isEmpty != false { return "Enable an app in Apps to recover its alerts." }
        if !permissionGranted { return "Grant Accessibility access to Notifdex in System Settings." }
        if recovering { return "A recovery scan is already running." }
        return nil
    }
}

private final class DatabaseOwner {
    private var descriptor: Int32 = -1
    init(url: URL) throws {
        let candidate = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard candidate >= 0 else { throw CaptureError(description: "Could not open the capture database lock") }
        if flock(candidate, LOCK_EX | LOCK_NB) != 0 {
            close(candidate)
            throw CaptureError(description: "Another collector is running. Stop the Terminal collector, then click Retry.")
        }
        descriptor = candidate
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}

/// Settings updates, UI navigation, and database writes all execute on one queue.
public final class CaptureWorker {
    public let directory: URL
    public var databaseURL: URL { directory.appendingPathComponent("capture.db") }
    private let queue = DispatchQueue(label: "com.notifdex.capture", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var owner: DatabaseOwner?
    private var store: CaptureStore?
    private var runID: String?
    private var state = AppCaptureState()
    private var settingsStore: AppSettingsStore { AppSettingsStore(url: directory.appendingPathComponent("settings.json")) }
    private var notify: ((AppCaptureState) -> Void)?
    private let isTrusted: () -> Bool
    private let isScreenLocked: () -> Bool
    private let readSnapshot: (String, Set<String>) throws -> Snapshot
    private let makeRecovery: () -> RecoverySession
    private let wakeSettleDelay: TimeInterval
    private let wakeRetryDelay: TimeInterval
    private let maxWakeRetries: Int
    private var needsRecovery = true
    private var recoveryFailed = false
    private var recoveryNotBefore: TimeInterval = 0
    private var wakeRetryCount = 0
    private var timerInterval: TimeInterval = 1.0
    private var automation: RecoverySession?
    private var recoveryInserted = 0
    private var recoveryDuplicateSightings = 0
    private var recoveryPeakObserved = 0
    private var lastPoll = Date().timeIntervalSince1970
    private var lastPermission = false

    public static func systemScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = dict["CGSSessionScreenIsLocked"] as? Bool else {
            return false
        }
        return locked
    }

    public convenience init(directory: URL) {
        self.init(
            directory: directory,
            isTrusted: AXIsProcessTrusted,
            isScreenLocked: CaptureWorker.systemScreenLocked,
            readSnapshot: snapshot(source:allowedApps:)
        )
    }

    init(directory: URL,
         isTrusted: @escaping () -> Bool,
         isScreenLocked: @escaping () -> Bool = { false },
         readSnapshot: @escaping (String, Set<String>) throws -> Snapshot,
         makeRecovery: @escaping () -> RecoverySession = { RecoveryAutomation() },
         wakeSettleDelay: TimeInterval = 1.5,
         wakeRetryDelay: TimeInterval = 3.0,
         maxWakeRetries: Int = 3) {
        self.directory = directory
        self.isTrusted = isTrusted
        self.isScreenLocked = isScreenLocked
        self.readSnapshot = readSnapshot
        self.makeRecovery = makeRecovery
        self.wakeSettleDelay = wakeSettleDelay
        self.wakeRetryDelay = wakeRetryDelay
        self.maxWakeRetries = maxWakeRetries
    }

    public func start(onChange: @escaping (AppCaptureState) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.notify = onChange
            guard self.timer == nil else { self.emit(); return }
            do {
                umask(0o077)
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                self.owner = try DatabaseOwner(url: self.databaseURL)
                let store = try CaptureStore(path: self.databaseURL.path)
                self.store = store
                let sources = try store.sourceIDs()
                let suffix = ":notificationcenter"
                let source = sources.count == 1 && sources[0].hasSuffix(suffix)
                    ? String(sources[0].dropLast(suffix.count)) : "mac-" + UUID().uuidString
                self.state.settings = try self.settingsStore.loadOrCreate(sourceID: source)
                self.needsRecovery = self.state.settings?.automaticRecovery ?? false
                self.recoveryFailed = false
                self.lastPermission = false
                self.lastPoll = Date().timeIntervalSince1970
                self.runID = try store.startRun(at: Date().timeIntervalSince1970)
                self.state.ready = true
                self.state.error = nil
                self.state.recoveryError = nil
                try self.refreshRows()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 1)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer
                timer.resume()
            } catch {
                self.state.status = "Capture could not start"
                self.state.error = String(describing: error)
                self.state.ready = false
                self.store = nil
                self.owner = nil
            }
            self.emit()
        }
    }

    public func updateSettings(_ change: @escaping (inout CaptureSettings) throws -> Void,
                               completion: @escaping () -> Void = {}) {
        queue.async {
            defer { onAppMainLoop(completion) }
            guard var settings = self.state.settings else { return }
            do {
                try change(&settings)
                try self.settingsStore.save(settings)
                self.endRecovery(reason: "Recovery stopped after a settings change")
                self.state.settings = settings
                self.state.error = nil
                self.needsRecovery = settings.automaticRecovery
            } catch { self.state.error = String(describing: error) }
            self.emit()
        }
    }

    /// Run inbox reads and edits on the same queue as the capture writer.
    public func withStore<Value>(_ operation: @escaping (CaptureStore) throws -> Value,
                                 completion: @escaping @MainActor (Result<Value, Error>) -> Void) {
        queue.async {
            let result = Result {
                guard self.state.ready, let store = self.store else {
                    throw CaptureError(description: "Open your Notifdex database before editing the inbox.")
                }
                return try operation(store)
            }
            onAppMainLoop { completion(result) }
        }
    }

    public func recoverNow() {
        queue.async {
            self.state.screenLocked = self.isScreenLocked()
            guard self.state.recoveryBlocker == nil else { self.emit(); return }
            self.needsRecovery = true
            self.recoveryNotBefore = 0
            self.wakeRetryCount = 0
            self.tick(manualRecovery: true)
        }
    }

    public func setSleeping(_ value: Bool) {
        queue.async {
            self.state.sleeping = value
            if value {
                self.endRecovery(reason: "Recovery stopped for sleep", finishTimeout: 0.5)
                self.wakeRetryCount = 0
                if let store = self.store, let run = self.runID {
                    do { try store.openGap(runID: run, reason: "sleep", at: Date().timeIntervalSince1970) }
                    catch { self.fail(error) }
                }
            } else {
                self.needsRecovery = self.state.settings?.automaticRecovery ?? false
                self.wakeRetryCount = 0
                self.recoveryNotBefore = Date().timeIntervalSince1970 + self.wakeSettleDelay
            }
            self.emit()
        }
    }

    public func setScreenLocked(_ value: Bool) {
        queue.async {
            let locked = value || self.isScreenLocked()
            self.state.screenLocked = locked
            if locked {
                let wasRecovering = self.automation != nil
                self.endRecovery(reason: "Recovery paused while screen is locked", finishTimeout: 0.5)
                if wasRecovering || (self.state.settings?.automaticRecovery == true && self.needsRecovery) {
                    self.needsRecovery = true
                }
            } else {
                self.wakeRetryCount = 0
                if self.needsRecovery {
                    self.recoveryNotBefore = Date().timeIntervalSince1970 + self.wakeSettleDelay
                    self.scheduleTimer(interval: min(self.timerInterval, max(0.1, self.wakeSettleDelay)))
                }
            }
            self.emit()
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        guard let timer = self.timer else { return }
        let clamped = max(0.1, interval)
        if abs(timerInterval - clamped) < 0.01 { return }
        timerInterval = clamped
        let ms = Int((clamped * 1000).rounded())
        timer.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
    }

    public func stop(completion: @escaping () -> Void) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.endRecovery(reason: "Recovery stopped", finishTimeout: 0.5)
            if let store = self.store, let run = self.runID {
                do { try store.finishRun(runID: run, at: Date().timeIntervalSince1970) }
                catch { self.state.error = String(describing: error) }
            }
            self.state.ready = false
            self.runID = nil
            self.store = nil
            self.owner = nil
            onAppMainLoop(completion)
        }
    }

    private func tick(manualRecovery: Bool = false) {
        guard state.ready, let store = store, let run = runID, let settings = state.settings else { return }
        let now = Date().timeIntervalSince1970
        let previousPoll = lastPoll
        let interrupted = now - previousPoll > 3 || now < previousPoll
        lastPoll = now
        state.permissionGranted = isTrusted()
        if state.permissionGranted && !lastPermission { needsRecovery = settings.automaticRecovery || manualRecovery }
        lastPermission = state.permissionGranted
        do {
            if interrupted { try store.openGap(runID: run, reason: "poll_interruption", at: min(now, previousPoll)) }
            guard !state.sleeping else { state.status = "Sleeping"; emit(); return }
            guard !settings.paused, !settings.allowedLabels.isEmpty else {
                endRecovery(reason: "Recovery stopped while capture is paused")
                try store.openGap(runID: run, reason: "paused", at: now)
                try store.heartbeat(runID: run, at: now)
                state.status = settings.paused ? "Paused" : "Enable an app to start collecting"
                emit()
                return
            }
            guard state.permissionGranted else {
                endRecovery(reason: "Recovery needs Accessibility permission")
                try store.openGap(runID: run, reason: "permission", at: now)
                try store.heartbeat(runID: run, at: now)
                state.status = "Accessibility permission needed"
                emit()
                return
            }
            let lockedNow = isScreenLocked()
            state.screenLocked = lockedNow
            if lockedNow && automation != nil {
                endRecovery(reason: "Recovery paused while screen is locked", finishTimeout: 0.5)
                if settings.automaticRecovery {
                    needsRecovery = true
                }
            }
            if !lockedNow && automation == nil && needsRecovery && (settings.automaticRecovery || manualRecovery) {
                if manualRecovery || now >= recoveryNotBefore {
                    needsRecovery = false
                    let recovery = makeRecovery()
                    do {
                        try recovery.begin()
                        automation = recovery
                        recoveryFailed = false
                        wakeRetryCount = 0
                        state.recoveryError = nil
                        recoveryInserted = 0
                        recoveryDuplicateSightings = 0
                        recoveryPeakObserved = 0
                        state.recovering = true
                        state.recoveryStatus = "Opening retained notifications"
                        state.status = "Recovering retained alerts"
                        scheduleTimer(interval: 0.45)
                        emit()
                        return // Let the panel settle before reading it.
                    } catch {
                        recoveryFailed = true
                        let message = String(describing: error)
                        state.recoveryStatus = message
                        state.recoveryError = message
                        try store.openGap(runID: run, reason: "recovery_navigation", at: now)
                        if !manualRecovery && settings.automaticRecovery && wakeRetryCount < maxWakeRetries {
                            wakeRetryCount += 1
                            needsRecovery = true
                            recoveryNotBefore = now + wakeRetryDelay
                            scheduleTimer(interval: min(1.0, wakeRetryDelay))
                        }
                    }
                }
            }
            let scan = try readSnapshot(settings.sourceID + ":notificationcenter", settings.allowedLabels)
            // Settings changes are serialized here, so disabling an app cancels the
            // navigation session before the next snapshot can persist that app.
            let accepted = scan.observations.filter { observation in
                guard let app = observation.appLabel else { return false }
                return settings.allowedLabels.contains(app)
            }
            let result = try store.recordBatch(accepted, runID: run, at: Date().timeIntervalSince1970)
            if result.inserted > 0 { state.lastSavedAt = Date() }
            state.lastScan = "Observed \(result.observed) · New \(result.inserted) · Duplicates \(result.duplicates) · Issues \(scan.issues.count)"
            state.status = automation == nil ? "Collecting accessible alerts" : "Recovering retained alerts"
            if scan.issues.isEmpty {
                state.error = nil
                try store.recover(runID: run, at: Date().timeIntervalSince1970,
                                  excluding: recoveryFailed ? ["recovery_navigation"] : [])
            } else {
                try store.openGap(runID: run, reason: "partial_scan", at: now)
                state.error = scan.issues.first
                state.lastCaptureIssue = scan.issues.first
            }
            if let recovery = automation {
                recoveryInserted += result.inserted
                recoveryDuplicateSightings += result.duplicates
                recoveryPeakObserved = max(recoveryPeakObserved, result.observed)
                do {
                    if let reason = try recovery.advance(allowedApps: settings.allowedLabels) {
                        endRecovery(reason: reason)
                        recoveryFailed = false
                        state.recoveryError = nil
                        if scan.issues.isEmpty {
                            state.error = nil
                            try store.recover(runID: run, at: Date().timeIntervalSince1970)
                        }
                    }
                } catch {
                    recoveryFailed = true
                    let message = String(describing: error)
                    endRecovery(reason: "Recovery navigation stopped: \(message)")
                    state.recoveryError = message
                    try store.openGap(runID: run, reason: "recovery_navigation", at: now)
                }
            }
            try refreshRows()
        } catch let error as CaptureError {
            endRecovery(reason: "Recovery stopped: \(error)")
            state.status = error.description
            state.lastCaptureIssue = error.description
            do {
                try store.openGap(runID: run, reason: "accessibility_unavailable", at: now)
                try store.heartbeat(runID: run, at: now)
            } catch { fail(error) }
        } catch { fail(error) }
        emit()
    }

    private func endRecovery(reason: String, finishTimeout: TimeInterval = 3) {
        guard let recovery = automation else { return }
        state.recoveryStatus = "Saved \(recoveryInserted); peak observed \(recoveryPeakObserved); duplicate sightings \(recoveryDuplicateSightings). \(reason)"
        do { try recovery.finish(timeout: finishTimeout) }
        catch { state.recoveryStatus += " Panel cleanup failed: \(error)" }
        automation = nil
        state.recovering = false
        scheduleTimer(interval: 1.0)
    }

    private func refreshRows() throws {
        guard let store = store else { return }
        state.recent = try store.recentObservations()
        state.summaries = try store.appSummaries()
        state.total = try store.observationCount()
    }

    private func fail(_ error: Error) {
        timer?.cancel()
        timer = nil
        endRecovery(reason: "Recovery stopped after a storage error", finishTimeout: 0.5)
        state.ready = false
        state.status = "Capture stopped after an error"
        state.error = String(describing: error)
        runID = nil
        store = nil
        owner = nil
    }

    private func emit() {
        let value = state
        let callback = notify
        onAppMainLoop { callback?(value) }
    }
}
#endif
