import Foundation

public struct CaptureApp: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var labels: Set<String>
    public var enabled: Bool

    public init(id: String, name: String, labels: Set<String>, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.labels = labels
        self.enabled = enabled
    }
}

public struct CaptureSettings: Codable, Equatable {
    fileprivate static let messagesApp = CaptureApp(id: "messages", name: "Messages", labels: ["Messages"])
    public var sourceID: String
    public var paused = false
    public var automaticRecovery = true
    public var apps: [CaptureApp]

    public init(sourceID: String) {
        self.sourceID = sourceID
        var messages = Self.messagesApp
        messages.enabled = true
        apps = [
            CaptureApp(id: "x", name: "X", labels: ["X", "Twitter"], enabled: true),
            CaptureApp(id: "discord", name: "Discord", labels: ["Discord"]),
            CaptureApp(id: "slack", name: "Slack", labels: ["Slack"]),
            CaptureApp(id: "gmail", name: "Gmail", labels: ["Gmail"]),
            CaptureApp(id: "linkedin", name: "LinkedIn", labels: ["LinkedIn"]),
            CaptureApp(id: "whatsapp", name: "WhatsApp", labels: ["WhatsApp"]),
            messages
        ]
    }

    public var allowedLabels: Set<String> {
        Set(apps.filter(\.enabled).flatMap(\.labels))
    }

    public mutating func addCustomApp(label: String) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !apps.contains(where: { $0.labels.contains(label) }) else {
            throw StoreError(description: "Enter a new, nonempty notification app label")
        }
        apps.append(CaptureApp(id: UUID().uuidString, name: label, labels: [label], enabled: true))
    }
}

public struct AppSettingsStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func loadOrCreate(sourceID: String) throws -> CaptureSettings {
        if FileManager.default.fileExists(atPath: url.path) {
            var settings = try JSONDecoder().decode(CaptureSettings.self, from: Data(contentsOf: url))
            guard !settings.sourceID.isEmpty else { throw StoreError(description: "Settings have no source identity") }
            let messages = CaptureSettings.messagesApp
            if !settings.apps.contains(where: { $0.id == messages.id || !$0.labels.isDisjoint(with: messages.labels) }) {
                settings.apps.append(messages)
            }
            return settings
        }
        let settings = CaptureSettings(sourceID: sourceID)
        try save(settings)
        return settings
    }

    public func save(_ settings: CaptureSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum RecoveryPolicy {
    public static func canExpand(subrole: String, app: String, allowed: Set<String>) -> Bool {
        subrole == "AXNotificationCenterBannerStack" && allowed.contains(app)
    }
}

public struct RecoveryBudget {
    private let maximumSteps: Int
    private let maximumUnchanged: Int
    private var steps = 0
    private var unchanged = 0
    private var lastFingerprint: String?

    public init(maximumSteps: Int = 40, maximumUnchanged: Int = 3) {
        self.maximumSteps = maximumSteps
        self.maximumUnchanged = maximumUnchanged
    }

    public var canContinue: Bool { steps < maximumSteps && unchanged < maximumUnchanged }

    public mutating func record(fingerprint: String, expandedStack: Bool) {
        unchanged = !expandedStack && lastFingerprint == fingerprint ? unchanged + 1 : 0
        lastFingerprint = fingerprint
        steps += 1
    }
}
