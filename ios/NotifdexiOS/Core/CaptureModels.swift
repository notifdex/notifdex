import Foundation

public enum CaptureChannel: String, Codable, Sendable, Equatable {
    case iosShortcuts = "ios_shortcuts"
    case manualTest = "manual_test"

    public var displayLabel: String {
        switch self {
        case .iosShortcuts: "iOS Shortcuts"
        case .manualTest: "Simulated Test"
        }
    }
}

public enum NotificationOrigin: String, Codable, Sendable, Equatable {
    case iphone
    case mac
    case unknown

    public var displayLabel: String {
        switch self {
        case .iphone: "iPhone"
        case .mac: "Mac"
        case .unknown: "Unknown"
        }
    }
}

public struct IncomingNotificationPayload: Equatable, Sendable {
    public var app: String
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var receivedAt: Date
    public var channel: CaptureChannel
    public var sourceMetadata: [String: String]

    public init(
        app: String,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        receivedAt: Date = Date(),
        channel: CaptureChannel = .iosShortcuts,
        sourceMetadata: [String: String] = [:]
    ) {
        self.app = app
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.receivedAt = receivedAt
        self.channel = channel
        self.sourceMetadata = sourceMetadata
    }
}

public struct NormalizedNotification: Equatable, Sendable {
    public var appLabel: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var dedupKey: String
    public var capturedAt: Double
    public var channel: CaptureChannel
    public var origin: NotificationOrigin
    public var metadataJSON: String

    public init(
        appLabel: String,
        title: String,
        subtitle: String,
        body: String,
        dedupKey: String,
        capturedAt: Double,
        channel: CaptureChannel,
        origin: NotificationOrigin,
        metadataJSON: String
    ) {
        self.appLabel = appLabel
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.dedupKey = dedupKey
        self.capturedAt = capturedAt
        self.channel = channel
        self.origin = origin
        self.metadataJSON = metadataJSON
    }
}

public struct CapturedNotification: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let captureUUID: String
    public let sourceID: String
    public let sourceEventID: String
    public let captureChannel: CaptureChannel
    public let origin: NotificationOrigin
    public let appLabel: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let capturedAt: Double
    public let deviceID: String
    public let metadataJSON: String

    public init(
        id: Int64,
        captureUUID: String,
        sourceID: String,
        sourceEventID: String,
        captureChannel: CaptureChannel,
        origin: NotificationOrigin,
        appLabel: String,
        title: String,
        subtitle: String,
        body: String,
        capturedAt: Double,
        deviceID: String,
        metadataJSON: String
    ) {
        self.id = id
        self.captureUUID = captureUUID
        self.sourceID = sourceID
        self.sourceEventID = sourceEventID
        self.captureChannel = captureChannel
        self.origin = origin
        self.appLabel = appLabel
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.capturedAt = capturedAt
        self.deviceID = deviceID
        self.metadataJSON = metadataJSON
    }

    public var capturedDate: Date {
        Date(timeIntervalSince1970: capturedAt)
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !subtitle.isEmpty { return subtitle }
        return appLabel
    }

    public var displayPreview: String {
        if !body.isEmpty { return body }
        if !subtitle.isEmpty && subtitle != displayTitle { return subtitle }
        return "No message body exposed"
    }
}

public enum CaptureSkipReason: Equatable, Sendable {
    case capturePaused
    case appDisabled(String)
    case emptyPayload

    public var message: String {
        switch self {
        case .capturePaused:
            "Capture is paused in Notifdex."
        case .appDisabled(let app):
            "\(app) capture is turned off in Notifdex."
        case .emptyPayload:
            "Notification had no app name or content to capture."
        }
    }
}

public enum CaptureOutcome: Equatable, Sendable {
    case captured(CapturedNotification)
    case duplicate(CapturedNotification)
    case skipped(CaptureSkipReason)

    public var summaryMessage: String {
        switch self {
        case .captured(let item):
            "Captured \(item.appLabel) notification."
        case .duplicate(let item):
            "Already captured this \(item.appLabel) notification."
        case .skipped(let reason):
            reason.message
        }
    }
}

public struct CaptureAppConfig: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var labels: [String]
    public var enabled: Bool
    public var isBuiltIn: Bool

    public init(id: String, name: String, labels: [String], enabled: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.labels = labels
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
    }

    public func matches(appLabel: String) -> Bool {
        let normalized = CaptureNormalizer.normalizeAppLabel(appLabel).lowercased()
        return labels.contains { CaptureNormalizer.normalizeAppLabel($0).lowercased() == normalized }
            || CaptureNormalizer.normalizeAppLabel(name).lowercased() == normalized
    }
}

public enum AppAutomationStatus: Equatable, Sendable {
    case active(lastCapturedAt: Double, count: Int)
    case awaitingShortcut
    case paused(count: Int)
}

public struct CaptureSettingsState: Codable, Equatable, Sendable {
    public var deviceID: String
    public var sourceID: String
    public var paused: Bool
    public var apps: [CaptureAppConfig]
    public var verifiedAppLabels: [String]

    public init(
        deviceID: String,
        sourceID: String? = nil,
        paused: Bool = false,
        apps: [CaptureAppConfig] = CaptureSettingsState.defaultApps,
        verifiedAppLabels: [String] = []
    ) {
        self.deviceID = deviceID
        self.sourceID = sourceID ?? "\(deviceID):ios_shortcuts"
        self.paused = paused
        self.apps = apps
        self.verifiedAppLabels = verifiedAppLabels
    }

    public static let defaultApps: [CaptureAppConfig] = [
        CaptureAppConfig(id: "x", name: "X", labels: ["X", "Twitter"], enabled: true, isBuiltIn: true),
        CaptureAppConfig(id: "gmail", name: "Gmail", labels: ["Gmail"], enabled: true, isBuiltIn: true),
        CaptureAppConfig(id: "wechat", name: "WeChat", labels: ["WeChat", "微信"], enabled: true, isBuiltIn: true),
        CaptureAppConfig(id: "messages", name: "Messages", labels: ["Messages"], enabled: false, isBuiltIn: true),
        CaptureAppConfig(id: "whatsapp", name: "WhatsApp", labels: ["WhatsApp"], enabled: false, isBuiltIn: true),
        CaptureAppConfig(id: "slack", name: "Slack", labels: ["Slack"], enabled: false, isBuiltIn: true),
        CaptureAppConfig(id: "discord", name: "Discord", labels: ["Discord"], enabled: false, isBuiltIn: true),
        CaptureAppConfig(id: "linkedin", name: "LinkedIn", labels: ["LinkedIn"], enabled: false, isBuiltIn: true)
    ]

    public func isAppEnabled(_ appLabel: String) -> Bool {
        if let matched = apps.first(where: { $0.matches(appLabel: appLabel) }) {
            return matched.enabled
        }
        // Unlisted apps are enabled if the user explicitly created a Shortcuts automation for them.
        return true
    }

    public func isVerified(app: CaptureAppConfig) -> Bool {
        verifiedAppLabels.contains { app.matches(appLabel: $0) }
    }
}

public struct IntentExecutionLogEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Double
    public let appLabel: String
    public let outcome: String
    public let detail: String

    public init(id: Int64, timestamp: Double, appLabel: String, outcome: String, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.appLabel = appLabel
        self.outcome = outcome
        self.detail = detail
    }

    public var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}

public struct CaptureStats: Equatable, Sendable {
    public let totalCount: Int
    public let lastCapturedAt: Double?
    public let countByApp: [String: Int]
    public let lastCapturedByApp: [String: Double]

    public init(
        totalCount: Int = 0,
        lastCapturedAt: Double? = nil,
        countByApp: [String: Int] = [:],
        lastCapturedByApp: [String: Double] = [:]
    ) {
        self.totalCount = totalCount
        self.lastCapturedAt = lastCapturedAt
        self.countByApp = countByApp
        self.lastCapturedByApp = lastCapturedByApp
    }
}

public struct CaptureStoreError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
