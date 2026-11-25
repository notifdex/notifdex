import Foundation

public enum PersonSuggestionReason: Equatable {
    case savedHandle(platform: String)
    case displayName
}

public struct PersonSuggestion: Equatable {
    public let person: PersonRecord
    public let reason: PersonSuggestionReason

    public init(person: PersonRecord, reason: PersonSuggestionReason) {
        self.person = person
        self.reason = reason
    }
}

public enum ContactSuggestionMatch: Equatable {
    case single(PersonSuggestion)
    case ambiguous([PersonRecord])
}

/// Pure, read-only contact hints derived from observed notification text and stored people/handles.
/// Never auto-creates or auto-merges people; callers always require explicit user confirmation.
public enum ContactSuggestions {
    public static let supportedPlatforms = [
        "Messages", "X", "Gmail", "WhatsApp", "LinkedIn", "Slack", "Discord"
    ]

    public static func availablePlatforms(
        configuredApps: [CaptureApp],
        observedApps: [String] = [],
        selectedPlatform: String? = nil
    ) -> [String] {
        var result = supportedPlatforms
        var seen = Set(result.map { $0.lowercased() })
        var extras: [String] = []

        func appendIfNew(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "Unknown app" else { return }
            let normalized = trimmed == "Twitter" ? "X" : trimmed
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { return }
            extras.append(normalized)
        }

        for app in configuredApps {
            appendIfNew(app.name)
        }
        for label in observedApps {
            appendIfNew(label)
        }
        if let selectedPlatform {
            appendIfNew(selectedPlatform)
        }

        extras.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        result.append(contentsOf: extras)
        return result
    }

    public static func defaultPlatform(for alertApp: String) -> String {
        let trimmed = alertApp.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "Twitter" { return "X" }
        if supportedPlatforms.contains(trimmed) { return trimmed }
        if !trimmed.isEmpty, trimmed != "Unknown app" { return trimmed }
        return "Messages"
    }

    public static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in String(word.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "?" }
        if words.count == 1 {
            return String(first.prefix(2)).uppercased()
        }
        guard let last = words.last, let a = first.first, let b = last.first else {
            return String(first.prefix(2)).uppercased()
        }
        return "\(a)\(b)".uppercased()
    }

    public static func looksLikeIdentifier(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // @handle (no internal whitespace)
        if trimmed.hasPrefix("@"), trimmed.count >= 2,
           !trimmed.contains(where: { $0.isWhitespace }) {
            return true
        }

        // Email address (local@domain.tld, no whitespace)
        if !trimmed.contains(where: { $0.isWhitespace }) {
            let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
            if parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
               !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") {
                return true
            }
        }

        // Phone number: only phone punctuation + digits, 7...15 digits
        let allowedPhoneChars = CharacterSet(charactersIn: "+0123456789 ()-.")
        if trimmed.unicodeScalars.allSatisfy({ allowedPhoneChars.contains($0) }) {
            let digits = trimmed.filter(\.isNumber)
            if (7...15).contains(digits.count) {
                return true
            }
        }

        return false
    }

    public static func hasMatchingHandle(
        _ title: String,
        app: String,
        in identities: [PersonIdentity]
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let appPlatform = defaultPlatform(for: app)
        return identities.contains { identity in
            matchesHandle(title: trimmed, alertPlatform: appPlatform, identity: identity)
        }
    }

    public static func suggest(
        for entry: InboxEntry,
        people: [PersonRecord],
        identitiesByPerson: [String: [PersonIdentity]]
    ) -> ContactSuggestionMatch? {
        guard entry.personID == nil else { return nil }
        let trimmed = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let alertPlatform = defaultPlatform(for: entry.app)
        var handleMatches: [(person: PersonRecord, platform: String, samePlatform: Bool)] = []
        for person in people {
            guard let identities = identitiesByPerson[person.id], !identities.isEmpty else { continue }
            if let same = identities.first(where: {
                $0.platform.caseInsensitiveCompare(alertPlatform) == .orderedSame
                    && matchesHandle(title: trimmed, alertPlatform: alertPlatform, identity: $0)
            }) {
                handleMatches.append((person, same.platform, true))
            } else if let any = identities.first(where: {
                matchesHandle(title: trimmed, alertPlatform: alertPlatform, identity: $0)
            }) {
                handleMatches.append((person, any.platform, false))
            }
        }

        if !handleMatches.isEmpty {
            let preferred = handleMatches.filter(\.samePlatform)
            let candidates = preferred.isEmpty ? handleMatches : preferred
            if candidates.count == 1, let match = candidates.first {
                return .single(PersonSuggestion(person: match.person, reason: .savedHandle(platform: match.platform)))
            }
            return .ambiguous(candidates.map(\.person))
        }

        let nameMatches = people.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if nameMatches.count == 1, let person = nameMatches.first {
            return .single(PersonSuggestion(person: person, reason: .displayName))
        }
        if nameMatches.count > 1 {
            return .ambiguous(nameMatches)
        }
        return nil
    }

    private static func matchesHandle(
        title: String,
        alertPlatform: String,
        identity: PersonIdentity
    ) -> Bool {
        let idTrimmed = identity.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idTrimmed.isEmpty else { return false }

        if idTrimmed.caseInsensitiveCompare(title) == .orderedSame {
            return true
        }

        // Normalize @handles for X / social handles
        let normalizedTitle = title.hasPrefix("@") ? String(title.dropFirst()) : title
        let normalizedID = idTrimmed.hasPrefix("@") ? String(idTrimmed.dropFirst()) : idTrimmed
        if (alertPlatform == "X" || identity.platform == "X"),
           normalizedTitle.caseInsensitiveCompare(normalizedID) == .orderedSame {
            return true
        }

        // Phone digit normalization when both look like phone numbers
        if looksLikePhone(title) && looksLikePhone(idTrimmed) {
            let d1 = title.filter(\.isNumber)
            let d2 = idTrimmed.filter(\.isNumber)
            if d1 == d2 { return true }
            if d1.count == 11, d1.hasPrefix("1"), String(d1.dropFirst()) == d2 { return true }
            if d2.count == 11, d2.hasPrefix("1"), String(d2.dropFirst()) == d1 { return true }
        }

        return false
    }

    private static func looksLikePhone(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let digits = text.filter(\.isNumber)
        return (7...15).contains(digits.count)
    }
}
