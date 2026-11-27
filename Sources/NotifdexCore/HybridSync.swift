import Foundation
import CSQLite
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum SyncCaptureChannel: String, Codable, Sendable, Equatable {
    case macosAX = "macos_ax"
    case iosShortcuts = "ios_shortcuts"
    case manualTest = "manual_test"
    case remoteSync = "remote_sync"

    public var displayLabel: String {
        switch self {
        case .macosAX: "Mac Notification Center"
        case .iosShortcuts: "iPhone Shortcuts"
        case .manualTest: "Simulated Test"
        case .remoteSync: "Synced"
        }
    }
}

public enum SyncDevicePlatform: String, Codable, Sendable, Equatable {
    case mac
    case iphone
    case ipad
    case unknown

    public var displayLabel: String {
        switch self {
        case .mac: "Mac"
        case .iphone: "iPhone"
        case .ipad: "iPad"
        case .unknown: "Device"
        }
    }
}

public enum SyncDeviceStatus: String, Codable, Sendable, Equatable {
    case localOnly = "local_only"
    case paired
    case revoked
}

public struct SyncDeviceRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { deviceID }
    public let deviceID: String
    public let displayName: String
    public let platform: SyncDevicePlatform
    public let status: SyncDeviceStatus
    public let pairedAt: Double?
    public let revokedAt: Double?
    public let lastSyncedAt: Double?

    public init(
        deviceID: String,
        displayName: String,
        platform: SyncDevicePlatform,
        status: SyncDeviceStatus,
        pairedAt: Double? = nil,
        revokedAt: Double? = nil,
        lastSyncedAt: Double? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.status = status
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
        self.lastSyncedAt = lastSyncedAt
    }
}

public struct ObservationProvenance: Equatable, Sendable {
    public let observationID: Int64
    public let syncUUID: String
    public let sourceID: String
    public let origin: NotificationOrigin
    public let channel: SyncCaptureChannel
    public let originDeviceID: String
    public let logicalKey: String
    public let workflowVersion: Int
    public let updatedAt: Double

    public var sourceBadge: String {
        switch channel {
        case .iosShortcuts: "iPhone"
        case .macosAX: origin == .iphone ? "iPhone via Mac" : "Mac"
        case .manualTest: "Test"
        case .remoteSync: origin == .iphone ? "iPhone" : "Mac"
        }
    }
}

public struct HybridInboxItem: Identifiable, Equatable {
    public var id: Int64 { primary.id }
    public let primary: InboxEntry
    public let observationIDs: [Int64]
    public let provenanceBadges: [String]
    public let channels: [SyncCaptureChannel]
}

public enum HybridInboxProjection {
    /// Collapses observations of the same logical alert seen by multiple devices within `windowSeconds`
    /// while preserving all underlying provenance badges and never deleting raw rows.
    public static func collapse(
        _ entries: [InboxEntry],
        provenanceByID: [Int64: ObservationProvenance],
        windowSeconds: Double = 300
    ) -> [HybridInboxItem] {
        var groups: [HybridInboxItem] = []

        for entry in entries {
            let prov = provenanceByID[entry.id]
            let key = prov?.logicalKey ?? SyncLogicalKey.make(
                appLabel: entry.app,
                title: entry.title,
                subtitle: entry.subtitle,
                body: entry.body
            )
            let badge = prov?.sourceBadge ?? "Mac"
            let channel = prov?.channel ?? .macosAX

            if let idx = groups.firstIndex(where: { existing in
                let existingKey = provenanceByID[existing.primary.id]?.logicalKey ?? SyncLogicalKey.make(
                    appLabel: existing.primary.app,
                    title: existing.primary.title,
                    subtitle: existing.primary.subtitle,
                    body: existing.primary.body
                )
                return existingKey == key && abs(existing.primary.capturedAt - entry.capturedAt) <= windowSeconds
            }) {
                let current = groups[idx]
                var badges = current.provenanceBadges
                if !badges.contains(badge) { badges.append(badge) }
                var channels = current.channels
                if !channels.contains(channel) { channels.append(channel) }
                groups[idx] = HybridInboxItem(
                    primary: current.primary,
                    observationIDs: current.observationIDs + [entry.id],
                    provenanceBadges: badges,
                    channels: channels
                )
            } else {
                groups.append(HybridInboxItem(
                    primary: entry,
                    observationIDs: [entry.id],
                    provenanceBadges: [badge],
                    channels: [channel]
                ))
            }
        }

        return groups
    }
}

public enum SyncLogicalKey {
    public static func make(appLabel: String, title: String, subtitle: String, body: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(Observation.appLabelDirectionMarks)
        let app = appLabel.trimmingCharacters(in: trimSet).lowercased()
        let canonical = [
            app == "twitter" ? "x" : app,
            title.trimmingCharacters(in: trimSet),
            subtitle.trimmingCharacters(in: trimSet),
            body.trimmingCharacters(in: trimSet)
        ].joined(separator: "\u{001F}")

        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return String(canonical.hashValue, radix: 16)
        #endif
    }

    public static func canonicalAppName(_ appLabel: String) -> String {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(Observation.appLabelDirectionMarks)
        let trimmed = appLabel.trimmingCharacters(in: trimSet)
        let lowered = trimmed.lowercased()
        if lowered == "twitter" || lowered == "x" {
            return "x"
        }
        return lowered
    }
}

// MARK: - Cross-Device macOS Forwarding Health Analyzer

public enum MacForwardingHealthStatus: String, Equatable, Sendable {
    case inactive
    case healthy
    case degraded
}

public struct MacForwardingHealthReport: Equatable, Sendable {
    public let status: MacForwardingHealthStatus
    public let affectedApps: [String]
    public let iosOnlyAlertCount: Int
    public let macForwardedAlertCount: Int
    public let summary: String
    public let remediationHint: String?

    public init(
        status: MacForwardingHealthStatus,
        affectedApps: [String],
        iosOnlyAlertCount: Int,
        macForwardedAlertCount: Int,
        summary: String,
        remediationHint: String?
    ) {
        self.status = status
        self.affectedApps = affectedApps
        self.iosOnlyAlertCount = iosOnlyAlertCount
        self.macForwardedAlertCount = macForwardedAlertCount
        self.summary = summary
        self.remediationHint = remediationHint
    }
}

/// Pure, public-API health analyzer mirroring `ForwardingHealthSoundness` in `spec/HybridSync.tla`.
/// Detects when a paired iPhone is syncing recent alerts via iOS Shortcuts for enabled apps while
/// macOS local Accessibility capture has observed zero alerts for those apps in the same window
/// (e.g., macOS `usernotificationsd` `-10814` / stale `appplaceholdersyncd` remote placeholders).
public enum MacForwardingHealthAnalyzer {
    public static func evaluate(
        isPaired: Bool,
        entries: [InboxEntry],
        provenanceByID: [Int64: ObservationProvenance],
        enabledApps: Set<String> = [],
        now: Double = Date().timeIntervalSince1970,
        windowSeconds: Double = 24 * 3600
    ) -> MacForwardingHealthReport {
        guard isPaired else {
            return MacForwardingHealthReport(
                status: .inactive,
                affectedApps: [],
                iosOnlyAlertCount: 0,
                macForwardedAlertCount: 0,
                summary: "Pair iOS & iCloud Sync to monitor macOS iPhone-forwarding health.",
                remediationHint: nil
            )
        }

        let canonicalEnabled = Set(enabledApps.map(SyncLogicalKey.canonicalAppName).filter { !$0.isEmpty })
        let earliest = now - max(0, windowSeconds)
        let recent = entries.filter { entry in
            guard entry.capturedAt >= earliest && entry.capturedAt <= now + 60 else { return false }
            if canonicalEnabled.isEmpty { return true }
            return canonicalEnabled.contains(SyncLogicalKey.canonicalAppName(entry.app))
        }

        var iosCountsByKey: [String: Int] = [:]
        var displayNameByKey: [String: String] = [:]
        var macLocalApps: Set<String> = []
        var macForwardedCount = 0

        for entry in recent {
            let key = SyncLogicalKey.canonicalAppName(entry.app)
            guard !key.isEmpty else { continue }
            if displayNameByKey[key] == nil {
                displayNameByKey[key] = entry.app.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let prov = provenanceByID[entry.id]
            let channel = prov?.channel ?? .macosAX
            switch channel {
            case .iosShortcuts:
                iosCountsByKey[key, default: 0] += 1
            case .macosAX:
                macLocalApps.insert(key)
                if prov?.origin == .iphone {
                    macForwardedCount += 1
                }
            case .manualTest, .remoteSync:
                break
            }
        }

        guard !iosCountsByKey.isEmpty else {
            return MacForwardingHealthReport(
                status: .inactive,
                affectedApps: [],
                iosOnlyAlertCount: 0,
                macForwardedAlertCount: macForwardedCount,
                summary: "No recent iPhone Shortcuts alerts synced in this window.",
                remediationHint: nil
            )
        }

        let missingKeys = iosCountsByKey.keys
            .filter { !macLocalApps.contains($0) }
            .sorted { lhs, rhs in
                (displayNameByKey[lhs] ?? lhs).localizedCaseInsensitiveCompare(displayNameByKey[rhs] ?? rhs) == .orderedAscending
            }

        if missingKeys.isEmpty {
            return MacForwardingHealthReport(
                status: .healthy,
                affectedApps: [],
                iosOnlyAlertCount: 0,
                macForwardedAlertCount: macForwardedCount,
                summary: "Mac Notification Center is receiving alerts for all recently synced iPhone apps.",
                remediationHint: nil
            )
        }

        let affectedApps = missingKeys.map { displayNameByKey[$0] ?? $0 }
        let iosOnlyCount = missingKeys.reduce(0) { $0 + (iosCountsByKey[$1] ?? 0) }
        let appList = affectedApps.joined(separator: ", ")
        return MacForwardingHealthReport(
            status: .degraded,
            affectedApps: affectedApps,
            iosOnlyAlertCount: iosOnlyCount,
            macForwardedAlertCount: macForwardedCount,
            summary: "Mac iPhone-forwarding appears degraded for \(appList) (\(iosOnlyCount) recent iPhone-only alert(s); iOS companion is covering capture).",
            remediationHint: "Check System Settings → Notifications → Allow notifications from iPhone. If an app is missing after a reset, update it in the iPhone App Store or Offload & Reinstall it (iPhone Settings → General → iPhone Storage) to refresh macOS placeholders."
        )
    }
}

// MARK: - Versioned Sync Envelope

public struct SyncedObservationRecord: Codable, Equatable, Sendable {
    public let syncUUID: String
    public let sourceID: String
    public let sourceEventID: String
    public let origin: NotificationOrigin
    public let captureChannel: SyncCaptureChannel
    public let originDeviceID: String
    public let appLabel: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let capturedAt: Double
    public let logicalKey: String
}

public struct SyncedWorkflowRecord: Codable, Equatable, Sendable {
    public let syncUUID: String
    public let isRead: Bool
    public let isFlagged: Bool
    public let saved: Bool
    public let dueAt: Double?
    public let done: Bool
    public let personID: String?
    public let workflowVersion: Int
    public let updatedAt: Double
}

public struct SyncedPersonRecord: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
}

public struct SyncedPersonNoteRecord: Codable, Equatable, Sendable {
    public let id: String
    public let personID: String
    public let title: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct SyncedNoteFolderRecord: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
}

public struct SyncedPersonalNoteRecord: Codable, Equatable, Sendable {
    public let id: String
    public let folderID: String?
    public let title: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct SyncTombstoneRecord: Codable, Equatable, Sendable {
    public let entityType: String
    public let entityID: String
    public let deletedAt: Double
}

public struct SyncBatch: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var senderDeviceID: String
    public var exportedAt: Double
    public var observations: [SyncedObservationRecord]
    public var workflows: [SyncedWorkflowRecord]
    public var people: [SyncedPersonRecord]
    public var personNotes: [SyncedPersonNoteRecord]
    public var noteFolders: [SyncedNoteFolderRecord]
    public var personalNotes: [SyncedPersonalNoteRecord]
    public var tombstones: [SyncTombstoneRecord]

    public init(
        senderDeviceID: String,
        exportedAt: Double,
        observations: [SyncedObservationRecord] = [],
        workflows: [SyncedWorkflowRecord] = [],
        people: [SyncedPersonRecord] = [],
        personNotes: [SyncedPersonNoteRecord] = [],
        noteFolders: [SyncedNoteFolderRecord] = [],
        personalNotes: [SyncedPersonalNoteRecord] = [],
        tombstones: [SyncTombstoneRecord] = []
    ) {
        self.senderDeviceID = senderDeviceID
        self.exportedAt = exportedAt
        self.observations = observations
        self.workflows = workflows
        self.people = people
        self.personNotes = personNotes
        self.noteFolders = noteFolders
        self.personalNotes = personalNotes
        self.tombstones = tombstones
    }

    /// Deterministic content digest excluding `exportedAt` so unchanged sync runs skip redundant pushes.
    public func contentDigest() -> String {
        var canonical = self
        canonical.exportedAt = 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(canonical) else {
            return UUID().uuidString
        }
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return data.base64EncodedString()
        #endif
    }
}

public struct SyncApplySummary: Equatable, Sendable {
    public let insertedObservations: Int
    public let appliedWorkflows: Int
    public let appliedPeople: Int
    public let appliedNotes: Int
    public let appliedTombstones: Int

    public var hasChanges: Bool {
        insertedObservations > 0
            || appliedWorkflows > 0
            || appliedPeople > 0
            || appliedNotes > 0
            || appliedTombstones > 0
    }
}

public struct SyncRunResult: Equatable, Sendable {
    public let pushedObservations: Int
    public let pushedWorkflows: Int
    public let applied: SyncApplySummary
    public let syncedAt: Double
}

public struct SyncPullResult: Sendable {
    public let batches: [SyncBatch]
    public let nextToken: Data?

    public init(batches: [SyncBatch], nextToken: Data?) {
        self.batches = batches
        self.nextToken = nextToken
    }
}

public protocol SyncTransport: Sendable {
    func push(_ batch: SyncBatch) async throws
    func pull(since token: Data?) async throws -> SyncPullResult
}

/// Deterministic in-memory transport modeling a shared CloudKit private zone for TDD.
public actor InMemorySyncTransport: SyncTransport {
    private var storedBatches: [SyncBatch] = []

    public init() {}

    public func push(_ batch: SyncBatch) async throws {
        storedBatches.append(batch)
    }

    public func pull(since token: Data?) async throws -> SyncPullResult {
        let startIndex: Int
        if let token, let str = String(data: token, encoding: .utf8), let parsed = Int(str) {
            startIndex = max(0, min(parsed, storedBatches.count))
        } else {
            startIndex = 0
        }
        let slice = Array(storedBatches[startIndex...])
        let nextToken = Data(String(storedBatches.count).utf8)
        return SyncPullResult(batches: slice, nextToken: nextToken)
    }

    public func allPushedBatches() -> [SyncBatch] {
        storedBatches
    }
}

public struct HybridSyncCoordinator {
    public let store: CaptureStore
    public let transport: any SyncTransport

    public init(store: CaptureStore, transport: any SyncTransport) {
        self.store = store
        self.transport = transport
    }

    @discardableResult
    public func syncNow(localDeviceID: String, at time: Double = Date().timeIntervalSince1970) async throws -> SyncRunResult {
        guard try store.canDeviceSync(localDeviceID) else {
            throw StoreError(description: "Sync is not active for this device. Enable and pair sync first.")
        }

        let token = try store.syncChangeToken()
        let pullResult = try await transport.pull(since: token)

        var totalInserted = 0
        var totalWorkflows = 0
        var totalPeople = 0
        var totalNotes = 0
        var totalTombstones = 0

        for remoteBatch in pullResult.batches where remoteBatch.senderDeviceID != localDeviceID {
            let summary = try store.applySyncBatch(remoteBatch, localDeviceID: localDeviceID, at: time)
            totalInserted += summary.insertedObservations
            totalWorkflows += summary.appliedWorkflows
            totalPeople += summary.appliedPeople
            totalNotes += summary.appliedNotes
            totalTombstones += summary.appliedTombstones
        }

        if let nextToken = pullResult.nextToken {
            try store.saveSyncChangeToken(nextToken)
        }

        let outgoing = try store.exportSyncBatch(deviceID: localDeviceID, at: time)
        let digest = outgoing.contentDigest()
        let previousDigest = try store.lastPushedDigest()
        let pushedObs: Int
        let pushedWF: Int

        if digest != previousDigest {
            try await transport.push(outgoing)
            try store.saveLastPushedDigest(digest)
            pushedObs = outgoing.observations.count
            pushedWF = outgoing.workflows.count
        } else {
            pushedObs = 0
            pushedWF = 0
        }

        try store.markDeviceSynced(localDeviceID, at: time)

        return SyncRunResult(
            pushedObservations: pushedObs,
            pushedWorkflows: pushedWF,
            applied: SyncApplySummary(
                insertedObservations: totalInserted,
                appliedWorkflows: totalWorkflows,
                appliedPeople: totalPeople,
                appliedNotes: totalNotes,
                appliedTombstones: totalTombstones
            ),
            syncedAt: time
        )
    }
}

// MARK: - Automatic Bidirectional Sync Scheduler (mirrors spec/AutoSync.tla)

public enum AutoSyncPhase: String, Equatable, Sendable {
    case idle
    case debouncing
    case running
    case backoff
}

public enum AutoSyncTrigger: String, Equatable, Sendable {
    case localCapture
    case localEdit
    case foreground
    case remotePush
    case periodic
    case manual
}

public enum AutoSyncScheduleDirective: Equatable, Sendable {
    case none
    case runImmediately
    case scheduleAfter(Double)
    case cancelScheduled
}

/// Pure, deterministic state machine mirroring `spec/AutoSync.tla` verbatim.
/// Guarantees `SingleFlight`, `UnpairedNeverSchedules`, `DisabledAutoNeverArmsTimer`,
/// `BackoffBounded`, and `MidSyncTriggerNotDropped`.
public struct AutoSyncStateMachine: Equatable, Sendable {
    public let debounceSeconds: Double
    public let baseBackoffSeconds: Double
    public let maxBackoffSeconds: Double
    public let maxFailureStreak: Int

    public private(set) var paired: Bool = false
    public private(set) var autoEnabled: Bool = true
    public private(set) var phase: AutoSyncPhase = .idle
    public private(set) var pendingTrigger: Bool = false
    public private(set) var failureStreak: Int = 0

    public init(
        debounceSeconds: Double = 3.0,
        baseBackoffSeconds: Double = 10.0,
        maxBackoffSeconds: Double = 300.0,
        maxFailureStreak: Int = 5
    ) {
        self.debounceSeconds = max(0, debounceSeconds)
        self.baseBackoffSeconds = max(0.01, baseBackoffSeconds)
        self.maxBackoffSeconds = max(self.baseBackoffSeconds, maxBackoffSeconds)
        self.maxFailureStreak = max(1, maxFailureStreak)
    }

    public func nextBackoffDelay() -> Double {
        guard failureStreak > 0 else { return debounceSeconds }
        let multiplier = pow(2.0, Double(failureStreak - 1))
        return min(baseBackoffSeconds * multiplier, maxBackoffSeconds)
    }

    @discardableResult
    public mutating func setPaired(_ isPaired: Bool) -> AutoSyncScheduleDirective {
        guard isPaired != paired else { return .none }
        paired = isPaired
        if isPaired {
            if phase == .running {
                pendingTrigger = autoEnabled
                return .none
            }
            if autoEnabled {
                phase = .debouncing
                return .scheduleAfter(debounceSeconds)
            }
            phase = .idle
            return .none
        } else {
            // Revoke: immediately disarm timers & clear pending follow-ups.
            pendingTrigger = false
            failureStreak = 0
            if phase != .running {
                phase = .idle
                return .cancelScheduled
            }
            return .cancelScheduled
        }
    }

    @discardableResult
    public mutating func setAutoEnabled(_ enabled: Bool) -> AutoSyncScheduleDirective {
        guard enabled != autoEnabled else { return .none }
        autoEnabled = enabled
        if !enabled {
            if phase == .debouncing || phase == .backoff {
                phase = .idle
                pendingTrigger = false
                return .cancelScheduled
            }
            return .none
        } else {
            if paired && phase == .idle {
                phase = .debouncing
                return .scheduleAfter(debounceSeconds)
            }
            return .none
        }
    }

    @discardableResult
    public mutating func handleTrigger(_ trigger: AutoSyncTrigger) -> AutoSyncScheduleDirective {
        if trigger == .manual {
            guard paired else { return .none }
            if phase == .running {
                pendingTrigger = true
                return .none
            }
            phase = .running
            pendingTrigger = false
            return .runImmediately
        }

        guard paired && autoEnabled else { return .none }
        switch phase {
        case .idle:
            phase = .debouncing
            return .scheduleAfter(debounceSeconds)
        case .debouncing:
            return .none
        case .running:
            pendingTrigger = true
            return .none
        case .backoff:
            pendingTrigger = true
            return .none
        }
    }

    public mutating func beginScheduledRun() -> Bool {
        guard paired && autoEnabled && (phase == .debouncing || phase == .backoff) else {
            return false
        }
        phase = .running
        pendingTrigger = false
        return true
    }

    @discardableResult
    public mutating func finishSuccess() -> AutoSyncScheduleDirective {
        guard phase == .running else { return .none }
        failureStreak = 0
        if paired && autoEnabled && pendingTrigger {
            phase = .debouncing
            pendingTrigger = false
            return .scheduleAfter(debounceSeconds)
        }
        phase = .idle
        pendingTrigger = false
        return .none
    }

    @discardableResult
    public mutating func finishFailure() -> AutoSyncScheduleDirective {
        guard phase == .running else { return .none }
        if paired && autoEnabled {
            failureStreak = min(failureStreak + 1, maxFailureStreak)
            phase = .backoff
            pendingTrigger = true
            return .scheduleAfter(nextBackoffDelay())
        }
        failureStreak = 0
        phase = .idle
        pendingTrigger = false
        return .none
    }
}

/// Async single-flight debounced sync runner backed by `AutoSyncStateMachine`.
public actor AutoSyncEngine {
    public typealias SyncAction = @Sendable () async throws -> SyncRunResult
    public typealias CompletionCallback = @Sendable (SyncRunResult) -> Void
    public typealias FailureCallback = @Sendable (Error) -> Void
    public typealias PhaseCallback = @Sendable (AutoSyncPhase) -> Void

    private var machine: AutoSyncStateMachine
    private let periodicIntervalSeconds: Double?
    private let syncAction: SyncAction
    private let onSyncCompleted: CompletionCallback?
    private let onSyncFailed: FailureCallback?
    private let onPhaseChanged: PhaseCallback?

    private var scheduledTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var stopped = false

    public init(
        debounceSeconds: Double = 3.0,
        baseBackoffSeconds: Double = 10.0,
        maxBackoffSeconds: Double = 300.0,
        maxFailureStreak: Int = 5,
        periodicIntervalSeconds: Double? = nil,
        syncAction: @escaping SyncAction,
        onSyncCompleted: CompletionCallback? = nil,
        onSyncFailed: FailureCallback? = nil,
        onPhaseChanged: PhaseCallback? = nil
    ) {
        self.machine = AutoSyncStateMachine(
            debounceSeconds: debounceSeconds,
            baseBackoffSeconds: baseBackoffSeconds,
            maxBackoffSeconds: maxBackoffSeconds,
            maxFailureStreak: maxFailureStreak
        )
        self.periodicIntervalSeconds = periodicIntervalSeconds
        self.syncAction = syncAction
        self.onSyncCompleted = onSyncCompleted
        self.onSyncFailed = onSyncFailed
        self.onPhaseChanged = onPhaseChanged
    }

    public func currentPhase() -> AutoSyncPhase {
        machine.phase
    }

    public func configure(paired: Bool, autoEnabled: Bool) {
        stopped = false
        let d1 = machine.setAutoEnabled(autoEnabled)
        let d2 = machine.setPaired(paired)
        apply(d1)
        apply(d2)
        updatePeriodicLoop()
        onPhaseChanged?(machine.phase)
    }

    public func trigger(_ reason: AutoSyncTrigger) {
        guard !stopped else { return }
        let directive = machine.handleTrigger(reason)
        apply(directive)
        onPhaseChanged?(machine.phase)
    }

    public func stop() {
        stopped = true
        scheduledTask?.cancel()
        scheduledTask = nil
        periodicTask?.cancel()
        periodicTask = nil
        _ = machine.setPaired(false)
        onPhaseChanged?(machine.phase)
    }

    private func apply(_ directive: AutoSyncScheduleDirective) {
        switch directive {
        case .none:
            break
        case .cancelScheduled:
            scheduledTask?.cancel()
            scheduledTask = nil
        case .scheduleAfter(let seconds):
            scheduledTask?.cancel()
            let nanos = UInt64(max(0, seconds) * 1_000_000_000)
            scheduledTask = Task { [weak self] in
                if nanos > 0 {
                    try? await Task.sleep(nanoseconds: nanos)
                }
                guard !Task.isCancelled else { return }
                await self?.runScheduledIfReady()
            }
        case .runImmediately:
            scheduledTask?.cancel()
            scheduledTask = nil
            Task { [weak self] in
                await self?.executeRun()
            }
        }
    }

    private func runScheduledIfReady() async {
        guard !stopped else { return }
        guard machine.beginScheduledRun() else { return }
        onPhaseChanged?(machine.phase)
        await executeRun()
    }

    private func executeRun() async {
        do {
            let result = try await syncAction()
            let next = machine.finishSuccess()
            onPhaseChanged?(machine.phase)
            onSyncCompleted?(result)
            if !stopped {
                apply(next)
            }
        } catch {
            let next = machine.finishFailure()
            onPhaseChanged?(machine.phase)
            onSyncFailed?(error)
            if !stopped {
                apply(next)
            }
        }
    }

    private func updatePeriodicLoop() {
        periodicTask?.cancel()
        periodicTask = nil
        guard !stopped, machine.paired, machine.autoEnabled,
              let interval = periodicIntervalSeconds, interval > 0 else {
            return
        }
        let nanos = UInt64(interval * 1_000_000_000)
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { break }
                await self?.trigger(.periodic)
            }
        }
    }
}

// MARK: - CaptureStore Hybrid Capture & Sync Extension

public extension CaptureStore {
    private static let syncEnabledKey = "sync_enabled"
    private static let autoSyncEnabledKey = "auto_sync_enabled"
    private static let syncTokenKey = "sync_change_token"
    private static let lastPushedDigestKey = "sync_last_pushed_digest"
    private static let localDeviceIDKey = "local_device_id"

    /// Direct structured observation capture (used by iOS 27 Shortcuts AppIntent and tests).
    /// Applies transactional sliding-window deduplication so rapid retries across minute boundaries stay idempotent.
    @discardableResult
    func recordDirectObservation(
        sourceID: String,
        originDeviceID: String,
        appLabel: String,
        title: String,
        subtitle: String = "",
        body: String,
        capturedAt: Double,
        origin: NotificationOrigin = .iphone,
        channel: SyncCaptureChannel = .iosShortcuts,
        dedupWindowSeconds: Double = 60.0
    ) throws -> (observationID: Int64, syncUUID: String, inserted: Bool) {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(Observation.appLabelDirectionMarks)
        let cleanApp = appLabel.trimmingCharacters(in: trimSet)
        guard !cleanApp.isEmpty else {
            throw StoreError(description: "App label cannot be empty.")
        }
        guard capturedAt.isFinite else {
            throw StoreError(description: "Invalid capture timestamp.")
        }
        let cleanTitle = title.trimmingCharacters(in: trimSet)
        let cleanSubtitle = subtitle.trimmingCharacters(in: trimSet)
        let cleanBody = body.trimmingCharacters(in: trimSet)
        let logicalKey = SyncLogicalKey.make(
            appLabel: cleanApp,
            title: cleanTitle,
            subtitle: cleanSubtitle,
            body: cleanBody
        )

        return try transaction {
            if dedupWindowSeconds > 0 {
                let existing = try readRows("""
                    SELECT o.id, coalesce(l.sync_uuid, '')
                    FROM observations o
                    LEFT JOIN sync_observation_links l ON l.observation_id = o.id
                    WHERE o.source_id = ?
                      AND lower(o.app_label) = lower(?)
                      AND o.title = ?
                      AND o.subtitle = ?
                      AND o.body = ?
                      AND abs(o.captured_at - ?) <= ?
                    ORDER BY o.captured_at DESC, o.id DESC
                    LIMIT 1
                    """, strings: [sourceID, cleanApp, cleanTitle, cleanSubtitle, cleanBody],
                         numbers: [capturedAt, dedupWindowSeconds]) { row in
                    (sqlite3_column_int64(row, 0), columnString(row, 1))
                }
                if let match = existing.first {
                    let uuid = match.1.isEmpty ? try ensureSyncLinkInTransaction(
                        observationID: match.0,
                        channel: channel,
                        originDeviceID: originDeviceID,
                        logicalKey: logicalKey,
                        at: capturedAt
                    ) : match.1
                    return (match.0, uuid, false)
                }
            }

            let runID = "direct:\(sourceID)"
            try execute("""
                INSERT INTO capture_runs(id, started_at, heartbeat_at)
                VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET heartbeat_at = max(heartbeat_at, excluded.heartbeat_at)
                """, strings: [runID], numbers: [capturedAt, capturedAt])

            let syncUUID = UUID().uuidString
            let sourceEventID = "\(logicalKey):\(Int64((capturedAt * 1000).rounded()))"
            try execute("""
                INSERT INTO observations
                (source_id, source_event_id, run_id, origin, app_label, title, subtitle,
                 body, accessibility_description, captured_at, parser_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, strings: [sourceID, sourceEventID, runID, origin.rawValue, cleanApp, cleanTitle,
                               cleanSubtitle, cleanBody, ""],
                     numbers: [capturedAt, 1])

            let observationID = sqlite3_last_insert_rowid(database)
            try execute("""
                INSERT INTO sync_observation_links
                (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at)
                VALUES (?, ?, ?, ?, ?, 0, ?)
                """, strings: [String(observationID), syncUUID, channel.rawValue, originDeviceID, logicalKey],
                     numbers: [capturedAt])

            return (observationID, syncUUID, true)
        }
    }

    // MARK: - Opt-In Pairing & Revocation (mirrors spec/HybridSync.tla)

    func localSyncDeviceID() throws -> String {
        if let existing = try syncStateValue(for: Self.localDeviceIDKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        try setSyncStateValue(generated, for: Self.localDeviceIDKey)
        return generated
    }

    func isSyncEnabled() throws -> Bool {
        (try syncStateValue(for: Self.syncEnabledKey)) == "1"
    }

    func setSyncEnabled(_ enabled: Bool) throws {
        try setSyncStateValue(enabled ? "1" : "0", for: Self.syncEnabledKey)
    }

    func isAutoSyncEnabled() throws -> Bool {
        guard let value = try syncStateValue(for: Self.autoSyncEnabledKey) else {
            return true
        }
        return value != "0"
    }

    func setAutoSyncEnabled(_ enabled: Bool) throws {
        try setSyncStateValue(enabled ? "1" : "0", for: Self.autoSyncEnabledKey)
    }

    internal func bumpExistingSyncWorkflowVersion(for observationID: Int64, at time: Double = Date().timeIntervalSince1970) throws {
        try execute("""
            UPDATE sync_observation_links
            SET workflow_version = workflow_version + 1, updated_at = max(updated_at, ?)
            WHERE observation_id = ?
            """, numbersFirst: [time], strings: [String(observationID)])
    }

    func registerOrUpdateDevice(
        deviceID: String,
        displayName: String,
        platform: SyncDevicePlatform,
        status: SyncDeviceStatus,
        at time: Double = Date().timeIntervalSince1970
    ) throws {
        let pairedAt: Double? = status == .paired ? time : nil
        let revokedAt: Double? = status == .revoked ? time : nil
        try transaction {
            let existing = try readRows(
                "SELECT paired_at, revoked_at, last_synced_at FROM sync_devices WHERE device_id = ?",
                strings: [deviceID]
            ) { row in
                (
                    sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : sqlite3_column_double(row, 0),
                    sqlite3_column_type(row, 1) == SQLITE_NULL ? nil : sqlite3_column_double(row, 1),
                    sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : sqlite3_column_double(row, 2)
                )
            }.first

            if let existing {
                try execute("""
                    UPDATE sync_devices
                    SET display_name = ?, platform = ?, status = ?,
                        paired_at = coalesce(?, paired_at),
                        revoked_at = CASE WHEN ? = 'revoked' THEN coalesce(?, revoked_at) ELSE NULL END
                    WHERE device_id = ?
                    """, strings: [displayName, platform.rawValue, status.rawValue,
                                   pairedAt.map { String($0) }, status.rawValue,
                                   revokedAt.map { String($0) }, deviceID])
                _ = existing
            } else {
                let stmt = try prepare("""
                    INSERT INTO sync_devices (device_id, display_name, platform, status, paired_at, revoked_at, last_synced_at)
                    VALUES (?, ?, ?, ?, ?, ?, NULL)
                    """, strings: [deviceID, displayName, platform.rawValue, status.rawValue,
                                   pairedAt.map { String($0) }, revokedAt.map { String($0) }])
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
            }
        }
    }

    func pairDevice(
        deviceID: String,
        displayName: String,
        platform: SyncDevicePlatform,
        at time: Double = Date().timeIntervalSince1970
    ) throws {
        try setSyncEnabled(true)
        try registerOrUpdateDevice(
            deviceID: deviceID,
            displayName: displayName,
            platform: platform,
            status: .paired,
            at: time
        )
    }

    func revokeDevice(_ deviceID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try transaction {
            try execute("""
                UPDATE sync_devices SET status = 'revoked', revoked_at = ?
                WHERE device_id = ?
                """, numbersFirst: [time], strings: [deviceID])
            if let local = try syncStateValue(for: Self.localDeviceIDKey), local == deviceID {
                try setSyncStateValue("0", for: Self.syncEnabledKey)
            }
        }
    }

    func syncDevices() throws -> [SyncDeviceRecord] {
        try readRows("""
            SELECT device_id, display_name, platform, status, paired_at, revoked_at, last_synced_at
            FROM sync_devices
            ORDER BY coalesce(paired_at, 0) DESC, device_id
            """) { row in
            SyncDeviceRecord(
                deviceID: columnString(row, 0),
                displayName: columnString(row, 1),
                platform: SyncDevicePlatform(rawValue: columnString(row, 2)) ?? .unknown,
                status: SyncDeviceStatus(rawValue: columnString(row, 3)) ?? .localOnly,
                pairedAt: sqlite3_column_type(row, 4) == SQLITE_NULL ? nil : sqlite3_column_double(row, 4),
                revokedAt: sqlite3_column_type(row, 5) == SQLITE_NULL ? nil : sqlite3_column_double(row, 5),
                lastSyncedAt: sqlite3_column_type(row, 6) == SQLITE_NULL ? nil : sqlite3_column_double(row, 6)
            )
        }
    }

    func canDeviceSync(_ deviceID: String) throws -> Bool {
        guard try isSyncEnabled() else { return false }
        let status = try readRows(
            "SELECT status FROM sync_devices WHERE device_id = ?",
            strings: [deviceID]
        ) { columnString($0, 0) }.first
        return status == SyncDeviceStatus.paired.rawValue
    }

    func markDeviceSynced(_ deviceID: String, at time: Double) throws {
        try execute("UPDATE sync_devices SET last_synced_at = ? WHERE device_id = ?",
                    numbersFirst: [time], strings: [deviceID])
    }

    func syncChangeToken() throws -> Data? {
        guard let encoded = try syncStateValue(for: Self.syncTokenKey), !encoded.isEmpty else { return nil }
        return Data(base64Encoded: encoded)
    }

    func saveSyncChangeToken(_ token: Data) throws {
        try setSyncStateValue(token.base64EncodedString(), for: Self.syncTokenKey)
    }

    func lastPushedDigest() throws -> String? {
        try syncStateValue(for: Self.lastPushedDigestKey)
    }

    func saveLastPushedDigest(_ digest: String) throws {
        try setSyncStateValue(digest, for: Self.lastPushedDigestKey)
    }

    func macForwardingHealth(
        localDeviceID: String,
        enabledApps: Set<String> = [],
        now: Double = Date().timeIntervalSince1970,
        windowSeconds: Double = 24 * 3600
    ) throws -> MacForwardingHealthReport {
        let isPaired = try canDeviceSync(localDeviceID)
        guard isPaired else {
            return MacForwardingHealthAnalyzer.evaluate(
                isPaired: false,
                entries: [],
                provenanceByID: [:],
                enabledApps: enabledApps,
                now: now,
                windowSeconds: windowSeconds
            )
        }
        let entries = try inbox(InboxQuery(limit: 500))
        let provenance = try provenanceByObservationID()
        return MacForwardingHealthAnalyzer.evaluate(
            isPaired: true,
            entries: entries,
            provenanceByID: provenance,
            enabledApps: enabledApps,
            now: now,
            windowSeconds: windowSeconds
        )
    }

    // MARK: - Provenance & Workflow Version Tracking

    func provenanceByObservationID() throws -> [Int64: ObservationProvenance] {
        let rows = try readRows("""
            SELECT o.id, coalesce(l.sync_uuid, ''), o.source_id, o.origin,
                   coalesce(l.capture_channel, 'macos_ax'),
                   coalesce(l.origin_device_id, o.source_id),
                   coalesce(l.logical_key, ''),
                   coalesce(l.workflow_version, 0),
                   coalesce(l.updated_at, o.captured_at),
                   coalesce(o.app_label, ''), o.title, o.subtitle, o.body
            FROM observations o
            LEFT JOIN sync_observation_links l ON l.observation_id = o.id
            """) { row -> ObservationProvenance in
            let id = sqlite3_column_int64(row, 0)
            let existingKey = columnString(row, 6)
            let logicalKey = existingKey.isEmpty ? SyncLogicalKey.make(
                appLabel: columnString(row, 9),
                title: columnString(row, 10),
                subtitle: columnString(row, 11),
                body: columnString(row, 12)
            ) : existingKey
            return ObservationProvenance(
                observationID: id,
                syncUUID: columnString(row, 1),
                sourceID: columnString(row, 2),
                origin: NotificationOrigin(rawValue: columnString(row, 3)) ?? .unknown,
                channel: SyncCaptureChannel(rawValue: columnString(row, 4)) ?? .macosAX,
                originDeviceID: columnString(row, 5),
                logicalKey: logicalKey,
                workflowVersion: Int(sqlite3_column_int64(row, 7)),
                updatedAt: sqlite3_column_double(row, 8)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.observationID, $0) })
    }

    func bumpWorkflowVersion(for observationID: Int64, originDeviceID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try transaction {
            _ = try ensureSyncLinkInTransaction(
                observationID: observationID,
                channel: .macosAX,
                originDeviceID: originDeviceID,
                logicalKey: nil,
                at: time
            )
            try execute("""
                UPDATE sync_observation_links
                SET workflow_version = workflow_version + 1, updated_at = max(updated_at, ?)
                WHERE observation_id = ?
                """, numbersFirst: [time], strings: [String(observationID)])
        }
    }

    func recordSyncTombstone(entityType: String, entityID: String, at time: Double = Date().timeIntervalSince1970) throws {
        try execute("""
            INSERT INTO sync_tombstones (entity_type, entity_id, deleted_at)
            VALUES (?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET deleted_at = max(deleted_at, excluded.deleted_at)
            """, strings: [entityType, entityID], numbers: [time])
    }

    // MARK: - Filtered Sync Export & Idempotent Remote Apply

    /// Exports only non-hidden, non-tombstoned observations plus workflow/CRM records.
    /// Enforces `UnpairedOrRevokedNeverSyncs` and `HiddenNeverLeaksToCloudOrIPhone`.
    func exportSyncBatch(deviceID: String, at time: Double = Date().timeIntervalSince1970) throws -> SyncBatch {
        guard try canDeviceSync(deviceID) else {
            throw StoreError(description: "Device \(deviceID) is not paired for sync.")
        }

        return try transaction {
            let app = Self.appCategory
            let hiddenClause = """
                (EXISTS (SELECT 1 FROM hidden_observations h WHERE h.observation_id = o.id)
                 OR EXISTS (SELECT 1 FROM inbox_filters f WHERE f.app = \(app) AND f.field = 'title' AND f.value = o.title)
                 OR EXISTS (SELECT 1 FROM inbox_filters f WHERE f.app = \(app) AND f.field = 'body' AND f.value = o.body))
                """

            let eligibleRows = try readRows("""
                SELECT o.id, o.source_id, o.source_event_id, o.origin,
                       coalesce(o.app_label, ''), o.title, o.subtitle, o.body, o.captured_at,
                       coalesce(l.sync_uuid, ''),
                       coalesce(l.capture_channel, 'macos_ax'),
                       coalesce(l.origin_device_id, ?),
                       coalesce(l.logical_key, ''),
                       coalesce(l.workflow_version, 0),
                       coalesce(l.updated_at, o.captured_at),
                       EXISTS (SELECT 1 FROM read_observations r WHERE r.observation_id = o.id),
                       EXISTS (SELECT 1 FROM flagged_observations fl WHERE fl.observation_id = o.id),
                       coalesce(w.saved, 0),
                       w.due_at,
                       coalesce(w.done, 0),
                       po.person_id
                FROM observations o
                LEFT JOIN sync_observation_links l ON l.observation_id = o.id
                LEFT JOIN observation_work w ON w.observation_id = o.id
                LEFT JOIN person_observations po ON po.observation_id = o.id
                WHERE NOT \(hiddenClause)
                ORDER BY o.captured_at DESC, o.id DESC
                """, strings: [deviceID]) { row in
                (
                    id: sqlite3_column_int64(row, 0),
                    sourceID: columnString(row, 1),
                    sourceEventID: columnString(row, 2),
                    origin: NotificationOrigin(rawValue: columnString(row, 3)) ?? .unknown,
                    appLabel: columnString(row, 4),
                    title: columnString(row, 5),
                    subtitle: columnString(row, 6),
                    body: columnString(row, 7),
                    capturedAt: sqlite3_column_double(row, 8),
                    syncUUID: columnString(row, 9),
                    channel: SyncCaptureChannel(rawValue: columnString(row, 10)) ?? .macosAX,
                    originDeviceID: columnString(row, 11),
                    logicalKey: columnString(row, 12),
                    workflowVersion: Int(sqlite3_column_int64(row, 13)),
                    updatedAt: sqlite3_column_double(row, 14),
                    isRead: sqlite3_column_int(row, 15) != 0,
                    isFlagged: sqlite3_column_int(row, 16) != 0,
                    saved: sqlite3_column_int(row, 17) != 0,
                    dueAt: sqlite3_column_type(row, 18) == SQLITE_NULL ? nil : sqlite3_column_double(row, 18),
                    done: sqlite3_column_int(row, 19) != 0,
                    personID: sqlite3_column_type(row, 20) == SQLITE_NULL ? nil : columnString(row, 20)
                )
            }

            let tombstones = try readRows(
                "SELECT entity_type, entity_id, deleted_at FROM sync_tombstones"
            ) { row in
                SyncTombstoneRecord(
                    entityType: columnString(row, 0),
                    entityID: columnString(row, 1),
                    deletedAt: sqlite3_column_double(row, 2)
                )
            }
            let tombstonedObs = Set(tombstones.filter { $0.entityType == "observation" }.map(\.entityID))
            let tombstonedNotes = Set(tombstones.filter { $0.entityType == "personal_note" }.map(\.entityID))
            let tombstonedPersonNotes = Set(tombstones.filter { $0.entityType == "person_note" }.map(\.entityID))

            var observations: [SyncedObservationRecord] = []
            var workflows: [SyncedWorkflowRecord] = []

            for row in eligibleRows {
                let logicalKey = row.logicalKey.isEmpty ? SyncLogicalKey.make(
                    appLabel: row.appLabel, title: row.title, subtitle: row.subtitle, body: row.body
                ) : row.logicalKey
                let syncUUID = row.syncUUID.isEmpty ? try ensureSyncLinkInTransaction(
                    observationID: row.id,
                    channel: row.channel,
                    originDeviceID: row.originDeviceID,
                    logicalKey: logicalKey,
                    at: row.capturedAt
                ) : row.syncUUID

                if tombstonedObs.contains(syncUUID) { continue }

                observations.append(SyncedObservationRecord(
                    syncUUID: syncUUID,
                    sourceID: row.sourceID,
                    sourceEventID: row.sourceEventID,
                    origin: row.origin,
                    captureChannel: row.channel,
                    originDeviceID: row.originDeviceID,
                    appLabel: row.appLabel,
                    title: row.title,
                    subtitle: row.subtitle,
                    body: row.body,
                    capturedAt: row.capturedAt,
                    logicalKey: logicalKey
                ))

                let hasWorkflowState = row.workflowVersion > 0 || row.isRead || row.isFlagged
                    || row.saved || row.dueAt != nil || row.personID != nil
                if hasWorkflowState {
                    workflows.append(SyncedWorkflowRecord(
                        syncUUID: syncUUID,
                        isRead: row.isRead,
                        isFlagged: row.isFlagged,
                        saved: row.saved,
                        dueAt: row.dueAt,
                        done: row.done,
                        personID: row.personID,
                        workflowVersion: max(1, row.workflowVersion),
                        updatedAt: row.updatedAt
                    ))
                }
            }

            let syncedPeople = try people().map { SyncedPersonRecord(id: $0.id, displayName: $0.name) }
            let syncedFolders = try noteFolders().map { SyncedNoteFolderRecord(id: $0.id, name: $0.name) }
            let syncedPersonalNotes = try personalNotes()
                .filter { !tombstonedNotes.contains($0.id) }
                .map {
                    SyncedPersonalNoteRecord(
                        id: $0.id, folderID: $0.folderID, title: $0.title, body: $0.body,
                        createdAt: $0.createdAt, updatedAt: $0.updatedAt
                    )
                }

            var syncedPersonNotes: [SyncedPersonNoteRecord] = []
            for person in syncedPeople {
                for note in try personNotes(for: person.id) where !tombstonedPersonNotes.contains(note.id) {
                    syncedPersonNotes.append(SyncedPersonNoteRecord(
                        id: note.id, personID: person.id, title: note.title, body: note.body,
                        createdAt: note.createdAt, updatedAt: note.updatedAt
                    ))
                }
            }

            return SyncBatch(
                senderDeviceID: deviceID,
                exportedAt: time,
                observations: observations,
                workflows: workflows,
                people: syncedPeople,
                personNotes: syncedPersonNotes,
                noteFolders: syncedFolders,
                personalNotes: syncedPersonalNotes,
                tombstones: tombstones
            )
        }
    }

    @discardableResult
    func applySyncBatch(
        _ batch: SyncBatch,
        localDeviceID: String,
        at time: Double = Date().timeIntervalSince1970
    ) throws -> SyncApplySummary {
        guard try canDeviceSync(localDeviceID) else {
            throw StoreError(description: "Device \(localDeviceID) is not paired for sync.")
        }

        return try transaction {
            var appliedTombstones = 0
            for t in batch.tombstones {
                try execute("""
                    INSERT INTO sync_tombstones (entity_type, entity_id, deleted_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(entity_type, entity_id) DO UPDATE SET deleted_at = max(deleted_at, excluded.deleted_at)
                    """, strings: [t.entityType, t.entityID], numbers: [t.deletedAt])
                appliedTombstones += 1
                if t.entityType == "personal_note" {
                    try execute("DELETE FROM personal_notes WHERE id = ?", strings: [t.entityID])
                } else if t.entityType == "person_note" {
                    try execute("DELETE FROM person_notes WHERE id = ?", strings: [t.entityID])
                }
            }

            let allTombstones = try readRows("SELECT entity_type, entity_id FROM sync_tombstones") {
                (columnString($0, 0), columnString($0, 1))
            }
            let tombstonedObs = Set(allTombstones.filter { $0.0 == "observation" }.map(\.1))
            let tombstonedPersonalNotes = Set(allTombstones.filter { $0.0 == "personal_note" }.map(\.1))
            let tombstonedPersonNotes = Set(allTombstones.filter { $0.0 == "person_note" }.map(\.1))

            var appliedPeople = 0
            for person in batch.people {
                try execute("""
                    INSERT INTO people (id, display_name) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name
                    """, strings: [person.id, person.displayName])
                appliedPeople += 1
            }

            for folder in batch.noteFolders {
                try execute("""
                    INSERT INTO note_folders (id, name) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name
                    """, strings: [folder.id, folder.name])
            }

            var appliedNotes = 0
            for note in batch.personalNotes where !tombstonedPersonalNotes.contains(note.id) {
                try execute("""
                    INSERT INTO personal_notes (id, folder_id, title, body, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        folder_id = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.folder_id ELSE personal_notes.folder_id END,
                        title = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.title ELSE personal_notes.title END,
                        body = CASE WHEN excluded.updated_at >= personal_notes.updated_at THEN excluded.body ELSE personal_notes.body END,
                        updated_at = max(personal_notes.updated_at, excluded.updated_at)
                    """, strings: [note.id, note.folderID, note.title, note.body],
                         numbers: [note.createdAt, note.updatedAt])
                appliedNotes += 1
            }

            for note in batch.personNotes where !tombstonedPersonNotes.contains(note.id) {
                try execute("""
                    INSERT INTO person_notes (id, person_id, title, body, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = CASE WHEN excluded.updated_at >= person_notes.updated_at THEN excluded.title ELSE person_notes.title END,
                        body = CASE WHEN excluded.updated_at >= person_notes.updated_at THEN excluded.body ELSE person_notes.body END,
                        updated_at = max(person_notes.updated_at, excluded.updated_at)
                    """, strings: [note.id, note.personID, note.title, note.body],
                         numbers: [note.createdAt, note.updatedAt])
                appliedNotes += 1
            }

            var insertedObservations = 0
            for obs in batch.observations where !tombstonedObs.contains(obs.syncUUID) {
                let existingID = try readRows(
                    "SELECT observation_id FROM sync_observation_links WHERE sync_uuid = ? LIMIT 1",
                    strings: [obs.syncUUID]
                ) { sqlite3_column_int64($0, 0) }.first
                if existingID != nil { continue }

                let runID = "sync:\(obs.originDeviceID)"
                try execute("""
                    INSERT INTO capture_runs(id, started_at, heartbeat_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET heartbeat_at = max(heartbeat_at, excluded.heartbeat_at)
                    """, strings: [runID], numbers: [obs.capturedAt, obs.capturedAt])

                try execute("""
                    INSERT INTO observations
                    (source_id, source_event_id, run_id, origin, app_label, title, subtitle,
                     body, accessibility_description, captured_at, parser_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(source_id, source_event_id, origin, title, subtitle, body,
                                accessibility_description, parser_version) DO NOTHING
                    """, strings: [obs.sourceID, obs.sourceEventID, runID, obs.origin.rawValue,
                                   obs.appLabel, obs.title, obs.subtitle, obs.body, ""],
                         numbers: [obs.capturedAt, 1])

                let obsID: Int64
                if sqlite3_changes(database) > 0 {
                    obsID = sqlite3_last_insert_rowid(database)
                    insertedObservations += 1
                } else {
                    let matchedRows = try readRows("""
                        SELECT id FROM observations
                        WHERE source_id = ? AND source_event_id = ? AND title = ? AND body = ?
                        LIMIT 1
                        """, strings: [obs.sourceID, obs.sourceEventID, obs.title, obs.body]) {
                        sqlite3_column_int64($0, 0)
                    }
                    guard let matched = matchedRows.first else { continue }
                    obsID = matched
                }

                try execute("""
                    INSERT OR IGNORE INTO sync_observation_links
                    (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """, strings: [String(obsID), obs.syncUUID, obs.captureChannel.rawValue,
                                   obs.originDeviceID, obs.logicalKey],
                         numbers: [time])
            }

            var appliedWorkflows = 0
            for wf in batch.workflows where !tombstonedObs.contains(wf.syncUUID) {
                let linkRows = try readRows("""
                    SELECT observation_id, workflow_version, updated_at
                    FROM sync_observation_links WHERE sync_uuid = ? LIMIT 1
                    """, strings: [wf.syncUUID]) { row in
                    (
                        id: sqlite3_column_int64(row, 0),
                        version: Int(sqlite3_column_int64(row, 1)),
                        updatedAt: sqlite3_column_double(row, 2)
                    )
                }
                guard let link = linkRows.first else { continue }

                // Monotonic LWW conflict resolution: only apply newer version (or tie-break by newer timestamp).
                let isNewer = wf.workflowVersion > link.version
                    || (wf.workflowVersion == link.version && wf.updatedAt > link.updatedAt)
                guard isNewer else { continue }

                if wf.isRead {
                    try execute("INSERT OR IGNORE INTO read_observations (observation_id) VALUES (?)",
                                strings: [String(link.id)])
                } else {
                    try execute("DELETE FROM read_observations WHERE observation_id = ?",
                                strings: [String(link.id)])
                }

                if wf.isFlagged {
                    try execute("INSERT OR IGNORE INTO flagged_observations (observation_id) VALUES (?)",
                                strings: [String(link.id)])
                } else {
                    try execute("DELETE FROM flagged_observations WHERE observation_id = ?",
                                strings: [String(link.id)])
                }

                let savedNum: Double = wf.saved ? 1 : 0
                let doneNum: Double = (wf.dueAt != nil && wf.done) ? 1 : 0
                if let dueAt = wf.dueAt {
                    try execute("""
                        INSERT INTO observation_work (observation_id, saved, due_at, done)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(observation_id) DO UPDATE SET
                            saved = excluded.saved, due_at = excluded.due_at, done = excluded.done
                        """, strings: [String(link.id)], numbers: [savedNum, dueAt, doneNum])
                } else {
                    try execute("""
                        INSERT INTO observation_work (observation_id, saved, due_at, done)
                        VALUES (?, ?, NULL, 0)
                        ON CONFLICT(observation_id) DO UPDATE SET
                            saved = excluded.saved, due_at = NULL, done = 0
                        """, strings: [String(link.id)], numbers: [savedNum])
                }

                if let personID = wf.personID {
                    try execute("""
                        INSERT INTO person_observations (observation_id, person_id, method)
                        VALUES (?, ?, 'manual')
                        ON CONFLICT(observation_id) DO UPDATE SET person_id = excluded.person_id
                        """, strings: [String(link.id), personID])
                } else {
                    try execute("DELETE FROM person_observations WHERE observation_id = ?",
                                strings: [String(link.id)])
                }

                try execute("""
                    UPDATE sync_observation_links
                    SET workflow_version = ?, updated_at = max(updated_at, ?)
                    WHERE observation_id = ?
                    """, numbersFirst: [Double(wf.workflowVersion), wf.updatedAt],
                         strings: [String(link.id)])
                appliedWorkflows += 1
            }

            return SyncApplySummary(
                insertedObservations: insertedObservations,
                appliedWorkflows: appliedWorkflows,
                appliedPeople: appliedPeople,
                appliedNotes: appliedNotes,
                appliedTombstones: appliedTombstones
            )
        }
    }

    // MARK: - Internal Sync Helpers

    private func ensureSyncLinkInTransaction(
        observationID: Int64,
        channel: SyncCaptureChannel,
        originDeviceID: String,
        logicalKey: String?,
        at time: Double
    ) throws -> String {
        let existingRows = try readRows(
            "SELECT sync_uuid FROM sync_observation_links WHERE observation_id = ? LIMIT 1",
            strings: [String(observationID)]
        ) { columnString($0, 0) }
        if let existing = existingRows.first {
            return existing
        }

        let resolvedKey: String
        if let logicalKey, !logicalKey.isEmpty {
            resolvedKey = logicalKey
        } else {
            let fields = try readRows(
                "SELECT coalesce(app_label, ''), title, subtitle, body FROM observations WHERE id = ?",
                strings: [String(observationID)]
            ) { (columnString($0, 0), columnString($0, 1), columnString($0, 2), columnString($0, 3)) }.first
            resolvedKey = SyncLogicalKey.make(
                appLabel: fields?.0 ?? "",
                title: fields?.1 ?? "",
                subtitle: fields?.2 ?? "",
                body: fields?.3 ?? ""
            )
        }

        let syncUUID = UUID().uuidString
        try execute("""
            INSERT INTO sync_observation_links
            (observation_id, sync_uuid, capture_channel, origin_device_id, logical_key, workflow_version, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            """, strings: [String(observationID), syncUUID, channel.rawValue, originDeviceID, resolvedKey],
                 numbers: [time])
        return syncUUID
    }

    private func syncStateValue(for key: String) throws -> String? {
        try readRows("SELECT value FROM sync_state WHERE key = ? LIMIT 1", strings: [key]) {
            columnString($0, 0)
        }.first
    }

    private func setSyncStateValue(_ value: String, for key: String) throws {
        try execute("""
            INSERT INTO sync_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, strings: [key, value])
    }
}
