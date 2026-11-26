import SwiftUI

enum NotifdexTheme {
    static let prussian = Color(red: 0.28, green: 0.49, blue: 0.86)
    static let celadon = Color(red: 0.25, green: 0.62, blue: 0.54)
    static let sienna = Color(red: 0.82, green: 0.46, blue: 0.28)
    static let vermilion = Color(red: 0.84, green: 0.24, blue: 0.18)
    static let mineral = Color(red: 0.46, green: 0.48, blue: 0.52)

    static func color(for appLabel: String) -> Color {
        switch CaptureNormalizer.normalizeAppLabel(appLabel).lowercased() {
        case "x", "twitter":
            return Color.primary
        case "gmail":
            return vermilion
        case "wechat", "微信":
            return Color(red: 0.12, green: 0.68, blue: 0.32)
        case "messages":
            return Color.green
        case "whatsapp":
            return celadon
        case "slack":
            return Color(red: 0.46, green: 0.24, blue: 0.56)
        case "discord":
            return Color(red: 0.35, green: 0.40, blue: 0.95)
        case "linkedin":
            return prussian
        default:
            return sienna
        }
    }

    static func symbol(for appLabel: String) -> String {
        switch CaptureNormalizer.normalizeAppLabel(appLabel).lowercased() {
        case "x", "twitter":
            return "at"
        case "gmail":
            return "envelope.fill"
        case "wechat", "微信":
            return "message.fill"
        case "messages":
            return "bubble.left.fill"
        case "whatsapp":
            return "phone.bubble.fill"
        case "slack":
            return "number"
        case "discord":
            return "headphones"
        case "linkedin":
            return "briefcase.fill"
        default:
            return "bell.badge.fill"
        }
    }
}
