import Foundation

public enum NotificationOrigin: String, Codable {
    case iphone, mac, unknown
}

/// Evidence from a rendered alert. App labels and display names are unverified text.
public struct Observation: Codable {
    public var sourceID: String
    public var sourceEventID: String
    public var capturedAt: Double
    public var accessibilityDescription: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var parserVersion: Int { 1 }

    public init(sourceID: String, sourceEventID: String, capturedAt: Double,
                description: String, title: String, subtitle: String = "", body: String) {
        self.sourceID = sourceID
        self.sourceEventID = sourceEventID
        self.capturedAt = capturedAt
        self.accessibilityDescription = description
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    public var origin: NotificationOrigin {
        // Only the English suffix observed in the live probe is currently recognized.
        accessibilityDescription.hasSuffix(", from iPhone") ? .iphone : .unknown
    }

    public var appLabel: String? {
        // Anchor against the separately observed title, preserving commas in body/title.
        guard !title.isEmpty,
              let boundary = accessibilityDescription.range(of: ", " + title + ", "),
              boundary.lowerBound > accessibilityDescription.startIndex else { return nil }
        return String(accessibilityDescription[..<boundary.lowerBound])
    }
}
