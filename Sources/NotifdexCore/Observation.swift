import Foundation

public enum NotificationOrigin: String, Codable {
    case iphone, mac, unknown
}

/// Evidence from a rendered alert. App labels and display names are unverified text.
public struct Observation: Codable {
    public static let appLabelDirectionMarks = CharacterSet(charactersIn: "\u{061C}\u{200E}\u{200F}")

    public static func normalizedAppLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: appLabelDirectionMarks)
    }

    public static func leadingAppToken(in description: String) -> String? {
        let normalized = normalizedAppLabel(description)
        guard let comma = normalized.firstIndex(of: ",") else { return nil }
        let token = normalizedAppLabel(String(normalized[..<comma]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

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
        // Notification Center can surround the app label with directional marks.
        let label = String(accessibilityDescription[..<boundary.lowerBound])
            .trimmingCharacters(in: Self.appLabelDirectionMarks)
        return label.isEmpty ? nil : label
    }
}
