import Foundation
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
    /// Collapses observations of the same logical alert seen by **different** capture sources/devices
    /// within `windowSeconds` while preserving all underlying provenance badges, keeping identical
    /// same-device messages distinct, and never deleting raw rows.
    public static func collapse(
        _ entries: [InboxEntry],
        provenanceByID: [Int64: ObservationProvenance],
        windowSeconds: Double = 300
    ) -> [HybridInboxItem] {
        var groups: [HybridInboxItem] = []
        var groupKeys: [String] = []
        var groupSourceIDs: [Set<String>] = []

        for entry in entries {
            let prov = provenanceByID[entry.id]
            let key = prov?.logicalKey ?? SyncLogicalKey.make(
                appLabel: entry.app,
                title: entry.title,
                subtitle: entry.subtitle,
                body: entry.body
            )
            let sourceID = prov?.sourceID ?? "local:\(entry.id)"
            let badge = prov?.sourceBadge ?? "Mac"
            let channel = prov?.channel ?? .macosAX

            if let idx = groups.indices.first(where: { i in
                groupKeys[i] == key
                    && !groupSourceIDs[i].contains(sourceID)
                    && abs(groups[i].primary.capturedAt - entry.capturedAt) <= windowSeconds
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
                groupSourceIDs[idx].insert(sourceID)
            } else {
                groups.append(HybridInboxItem(
                    primary: entry,
                    observationIDs: [entry.id],
                    provenanceBadges: [badge],
                    channels: [channel]
                ))
                groupKeys.append(key)
                groupSourceIDs.append([sourceID])
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
    public let workspaceID: String?
    public let workflowVersion: Int
    public let updatedAt: Double

    public init(
        syncUUID: String,
        isRead: Bool,
        isFlagged: Bool,
        saved: Bool,
        dueAt: Double?,
        done: Bool,
        personID: String?,
        workspaceID: String? = nil,
        workflowVersion: Int,
        updatedAt: Double
    ) {
        self.syncUUID = syncUUID
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.saved = saved
        self.dueAt = dueAt
        self.done = done
        self.personID = personID
        self.workspaceID = workspaceID
        self.workflowVersion = workflowVersion
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        syncUUID = try c.decode(String.self, forKey: .syncUUID)
        isRead = try c.decode(Bool.self, forKey: .isRead)
        isFlagged = try c.decode(Bool.self, forKey: .isFlagged)
        saved = try c.decode(Bool.self, forKey: .saved)
        dueAt = try c.decodeIfPresent(Double.self, forKey: .dueAt)
        done = try c.decode(Bool.self, forKey: .done)
        personID = try c.decodeIfPresent(String.self, forKey: .personID)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        workflowVersion = try c.decode(Int.self, forKey: .workflowVersion)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
    }
}

/// Privacy-preserving individual hide/restore state marker. Carries zero notification text
/// so locally hidden Mac alerts never leak private content into CloudKit or onto iPhone.
public struct SyncedHiddenAlertRecord: Codable, Equatable, Sendable {
    public let syncUUID: String
    public let logicalKey: String
    public let isHidden: Bool
    public let hiddenVersion: Int
    public let updatedAt: Double

    public init(
        syncUUID: String,
        logicalKey: String,
        isHidden: Bool,
        hiddenVersion: Int,
        updatedAt: Double
    ) {
        self.syncUUID = syncUUID
        self.logicalKey = logicalKey
        self.isHidden = isHidden
        self.hiddenVersion = hiddenVersion
        self.updatedAt = updatedAt
    }
}

public struct SyncedHideRuleRecord: Codable, Equatable, Sendable {
    public let app: String
    public let field: InboxRuleMatch.Field
    public let value: String
    public let enabled: Bool
    public let updatedAt: Double

    public var canonicalKey: String {
        InboxRuleMatch(app: app, field: field, text: value).canonicalSyncKey
    }

    public init(
        app: String,
        field: InboxRuleMatch.Field,
        value: String,
        enabled: Bool = true,
        updatedAt: Double
    ) {
        self.app = app
        self.field = field
        self.value = field == .app ? app : value
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

public struct SyncedPersonRecord: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let updatedAt: Double

    public init(id: String, displayName: String, updatedAt: Double = 0) {
        self.id = id
        self.displayName = displayName
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

public struct SyncedIdentityRecord: Codable, Equatable, Sendable {
    public let id: String
    public let personID: String
    public let platform: String
    public let identifier: String
    public let updatedAt: Double

    public init(id: String, personID: String, platform: String, identifier: String, updatedAt: Double) {
        self.id = id
        self.personID = personID
        self.platform = platform
        self.identifier = identifier
        self.updatedAt = updatedAt
    }
}

public struct SyncedPersonMatchRuleRecord: Codable, Equatable, Sendable {
    public let id: String
    public let app: String
    public let title: String
    public let personID: String
    public let updatedAt: Double

    public init(id: String, app: String, title: String, personID: String, updatedAt: Double) {
        self.id = id
        self.app = app
        self.title = title
        self.personID = personID
        self.updatedAt = updatedAt
    }
}

public struct SyncedWorkspaceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let updatedAt: Double

    public init(id: String, name: String, updatedAt: Double) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }
}

public struct SyncedPersonWorkspaceRecord: Codable, Equatable, Sendable {
    public let personID: String
    public let workspaceID: String
    public let updatedAt: Double

    public init(personID: String, workspaceID: String, updatedAt: Double) {
        self.personID = personID
        self.workspaceID = workspaceID
        self.updatedAt = updatedAt
    }
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
    public let updatedAt: Double

    public init(id: String, name: String, updatedAt: Double = 0) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }
}

public struct SyncedPersonalNoteRecord: Codable, Equatable, Sendable {
    public let id: String
    public let folderID: String?
    public let title: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct SyncedRelationshipTemplateRecord: Codable, Equatable, Sendable {
    public let templateID: String
    public let version: Int
    public let definitionJSON: String

    public init(templateID: String, version: Int, definitionJSON: String) {
        self.templateID = templateID
        self.version = version
        self.definitionJSON = definitionJSON
    }
}

public struct SyncedPersonTemplateRecord: Codable, Equatable, Sendable {
    public let personID: String
    public let templateID: String
    public let version: Int
    public let stageID: String
    public let completedMilestones: [String]
    public let updatedAt: Double

    public init(
        personID: String,
        templateID: String,
        version: Int,
        stageID: String,
        completedMilestones: [String],
        updatedAt: Double
    ) {
        self.personID = personID
        self.templateID = templateID
        self.version = version
        self.stageID = stageID
        self.completedMilestones = completedMilestones
        self.updatedAt = updatedAt
    }
}

public struct SyncedUserPreferences: Codable, Equatable, Sendable {
    public let colorThemeRaw: String?
    public let groupByApp: Bool?
    public let updatedAt: Double

    public init(colorThemeRaw: String? = nil, groupByApp: Bool? = nil, updatedAt: Double) {
        self.colorThemeRaw = colorThemeRaw
        self.groupByApp = groupByApp
        self.updatedAt = updatedAt
    }
}

public struct SyncTombstoneRecord: Codable, Equatable, Sendable {
    public let entityType: String
    public let entityID: String
    public let deletedAt: Double
}

public struct SyncBatch: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 2
    public var senderDeviceID: String
    public var exportedAt: Double
    public var observations: [SyncedObservationRecord]
    public var workflows: [SyncedWorkflowRecord]
    public var people: [SyncedPersonRecord]
    public var personNotes: [SyncedPersonNoteRecord]
    public var noteFolders: [SyncedNoteFolderRecord]
    public var personalNotes: [SyncedPersonalNoteRecord]
    public var tombstones: [SyncTombstoneRecord]
    public var hideRules: [SyncedHideRuleRecord]
    public var hiddenAlerts: [SyncedHiddenAlertRecord]
    public var identities: [SyncedIdentityRecord]
    public var personMatchRules: [SyncedPersonMatchRuleRecord]
    public var workspaces: [SyncedWorkspaceRecord]
    public var personWorkspaces: [SyncedPersonWorkspaceRecord]
    public var relationshipTemplates: [SyncedRelationshipTemplateRecord]
    public var personTemplates: [SyncedPersonTemplateRecord]
    public var preferences: SyncedUserPreferences?

    public init(
        schemaVersion: Int = 2,
        senderDeviceID: String,
        exportedAt: Double,
        observations: [SyncedObservationRecord] = [],
        workflows: [SyncedWorkflowRecord] = [],
        people: [SyncedPersonRecord] = [],
        personNotes: [SyncedPersonNoteRecord] = [],
        noteFolders: [SyncedNoteFolderRecord] = [],
        personalNotes: [SyncedPersonalNoteRecord] = [],
        tombstones: [SyncTombstoneRecord] = [],
        hideRules: [SyncedHideRuleRecord] = [],
        hiddenAlerts: [SyncedHiddenAlertRecord] = [],
        identities: [SyncedIdentityRecord] = [],
        personMatchRules: [SyncedPersonMatchRuleRecord] = [],
        workspaces: [SyncedWorkspaceRecord] = [],
        personWorkspaces: [SyncedPersonWorkspaceRecord] = [],
        relationshipTemplates: [SyncedRelationshipTemplateRecord] = [],
        personTemplates: [SyncedPersonTemplateRecord] = [],
        preferences: SyncedUserPreferences? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.senderDeviceID = senderDeviceID
        self.exportedAt = exportedAt
        self.observations = observations
        self.workflows = workflows
        self.people = people
        self.personNotes = personNotes
        self.noteFolders = noteFolders
        self.personalNotes = personalNotes
        self.tombstones = tombstones
        self.hideRules = hideRules
        self.hiddenAlerts = hiddenAlerts
        self.identities = identities
        self.personMatchRules = personMatchRules
        self.workspaces = workspaces
        self.personWorkspaces = personWorkspaces
        self.relationshipTemplates = relationshipTemplates
        self.personTemplates = personTemplates
        self.preferences = preferences
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        senderDeviceID = try c.decode(String.self, forKey: .senderDeviceID)
        exportedAt = try c.decode(Double.self, forKey: .exportedAt)
        observations = try c.decodeIfPresent([SyncedObservationRecord].self, forKey: .observations) ?? []
        workflows = try c.decodeIfPresent([SyncedWorkflowRecord].self, forKey: .workflows) ?? []
        people = try c.decodeIfPresent([SyncedPersonRecord].self, forKey: .people) ?? []
        personNotes = try c.decodeIfPresent([SyncedPersonNoteRecord].self, forKey: .personNotes) ?? []
        noteFolders = try c.decodeIfPresent([SyncedNoteFolderRecord].self, forKey: .noteFolders) ?? []
        personalNotes = try c.decodeIfPresent([SyncedPersonalNoteRecord].self, forKey: .personalNotes) ?? []
        tombstones = try c.decodeIfPresent([SyncTombstoneRecord].self, forKey: .tombstones) ?? []
        hideRules = try c.decodeIfPresent([SyncedHideRuleRecord].self, forKey: .hideRules) ?? []
        hiddenAlerts = try c.decodeIfPresent([SyncedHiddenAlertRecord].self, forKey: .hiddenAlerts) ?? []
        identities = try c.decodeIfPresent([SyncedIdentityRecord].self, forKey: .identities) ?? []
        personMatchRules = try c.decodeIfPresent([SyncedPersonMatchRuleRecord].self, forKey: .personMatchRules) ?? []
        workspaces = try c.decodeIfPresent([SyncedWorkspaceRecord].self, forKey: .workspaces) ?? []
        personWorkspaces = try c.decodeIfPresent([SyncedPersonWorkspaceRecord].self, forKey: .personWorkspaces) ?? []
        relationshipTemplates = try c.decodeIfPresent([SyncedRelationshipTemplateRecord].self, forKey: .relationshipTemplates) ?? []
        personTemplates = try c.decodeIfPresent([SyncedPersonTemplateRecord].self, forKey: .personTemplates) ?? []
        preferences = try c.decodeIfPresent(SyncedUserPreferences.self, forKey: .preferences)
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
    public let appliedHideRules: Int
    public let appliedHiddenAlerts: Int
    public let appliedWorkspaces: Int
    public let appliedPreferences: Bool

    public init(
        insertedObservations: Int,
        appliedWorkflows: Int,
        appliedPeople: Int,
        appliedNotes: Int,
        appliedTombstones: Int,
        appliedHideRules: Int = 0,
        appliedHiddenAlerts: Int = 0,
        appliedWorkspaces: Int = 0,
        appliedPreferences: Bool = false
    ) {
        self.insertedObservations = insertedObservations
        self.appliedWorkflows = appliedWorkflows
        self.appliedPeople = appliedPeople
        self.appliedNotes = appliedNotes
        self.appliedTombstones = appliedTombstones
        self.appliedHideRules = appliedHideRules
        self.appliedHiddenAlerts = appliedHiddenAlerts
        self.appliedWorkspaces = appliedWorkspaces
        self.appliedPreferences = appliedPreferences
    }

    public var hasChanges: Bool {
        insertedObservations > 0
            || appliedWorkflows > 0
            || appliedPeople > 0
            || appliedNotes > 0
            || appliedTombstones > 0
            || appliedHideRules > 0
            || appliedHiddenAlerts > 0
            || appliedWorkspaces > 0
            || appliedPreferences
    }
}

public struct SyncRunResult: Equatable, Sendable {
    public let pushedObservations: Int
    public let pushedWorkflows: Int
    public let pushedHideRules: Int
    public let applied: SyncApplySummary
    public let syncedAt: Double

    public init(
        pushedObservations: Int,
        pushedWorkflows: Int,
        pushedHideRules: Int = 0,
        applied: SyncApplySummary,
        syncedAt: Double
    ) {
        self.pushedObservations = pushedObservations
        self.pushedWorkflows = pushedWorkflows
        self.pushedHideRules = pushedHideRules
        self.applied = applied
        self.syncedAt = syncedAt
    }
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
        var totalHideRules = 0
        var totalHiddenAlerts = 0
        var totalWorkspaces = 0
        var anyPreferences = false

        for remoteBatch in pullResult.batches where remoteBatch.senderDeviceID != localDeviceID {
            let summary = try store.applySyncBatch(remoteBatch, localDeviceID: localDeviceID, at: time)
            totalInserted += summary.insertedObservations
            totalWorkflows += summary.appliedWorkflows
            totalPeople += summary.appliedPeople
            totalNotes += summary.appliedNotes
            totalTombstones += summary.appliedTombstones
            totalHideRules += summary.appliedHideRules
            totalHiddenAlerts += summary.appliedHiddenAlerts
            totalWorkspaces += summary.appliedWorkspaces
            anyPreferences = anyPreferences || summary.appliedPreferences
        }

        if let nextToken = pullResult.nextToken {
            try store.saveSyncChangeToken(nextToken)
        }

        let outgoing = try store.exportSyncBatch(deviceID: localDeviceID, at: time)
        let digest = outgoing.contentDigest()
        let previousDigest = try store.lastPushedDigest()
        let pushedObs: Int
        let pushedWF: Int
        let pushedRules: Int

        if digest != previousDigest {
            try await transport.push(outgoing)
            try store.saveLastPushedDigest(digest)
            pushedObs = outgoing.observations.count
            pushedWF = outgoing.workflows.count
            pushedRules = outgoing.hideRules.count
        } else {
            pushedObs = 0
            pushedWF = 0
            pushedRules = 0
        }

        try store.markDeviceSynced(localDeviceID, at: time)

        return SyncRunResult(
            pushedObservations: pushedObs,
            pushedWorkflows: pushedWF,
            pushedHideRules: pushedRules,
            applied: SyncApplySummary(
                insertedObservations: totalInserted,
                appliedWorkflows: totalWorkflows,
                appliedPeople: totalPeople,
                appliedNotes: totalNotes,
                appliedTombstones: totalTombstones,
                appliedHideRules: totalHideRules,
                appliedHiddenAlerts: totalHiddenAlerts,
                appliedWorkspaces: totalWorkspaces,
                appliedPreferences: anyPreferences
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

