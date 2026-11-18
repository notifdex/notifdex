import Foundation

public struct InboxQuery: Equatable {
    public enum Scope: Equatable {
        case inbox(app: String?, saved: Bool)
        case flagged(app: String?)
        case hidden(app: String?)
        case person(String)
        case followUps
    }

    public enum ReadFilter: Hashable {
        case all, unread, read
    }

    public enum Order: Hashable {
        case newestFirst, oldestFirst
    }

    public var scope: Scope
    public var search: String
    public var limit: Int

    public var readFilter: ReadFilter
    public var order: Order

    public init(scope: Scope = .inbox(app: nil, saved: false), search: String = "", limit: Int = 50,
                readFilter: ReadFilter = .all, order: Order = .newestFirst) {
        self.scope = scope
        self.search = search
        self.limit = limit
        self.readFilter = readFilter
        self.order = order
    }
}

public struct InboxEntry: Identifiable, Equatable {
    public let id: Int64
    public let app: String
    public let title: String
    public let subtitle: String
    public let body: String
    public let capturedAt: Double
    public let saved: Bool
    public let dueAt: Double?
    public let done: Bool
    public let personID: String?
    public let personName: String
    public let subject: String
    public let individuallyHidden: Bool
    public let filtered: Bool
    public let isRead: Bool
    public let isFlagged: Bool
    public let personRuleID: String?
}

public struct PersonNote: Identifiable {
    public let id: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct PersonRecord: Identifiable, Equatable {
    public let id: String
    public let name: String
}

public struct PersonIdentity: Identifiable, Equatable {
    public let id: String
    public let platform: String
    public let identifier: String
}


public struct InboxFilter: Identifiable {
    public let id: Int64
    public let app: String
    public let subject: String
}


/// Static destinations keep notification text out of the URL we open.
public enum InboxDestination {
    public static func webURL(for app: String) -> URL? {
        let address: String
        switch app {
        case "X": address = "https://x.com/messages"
        case "Gmail": address = "https://mail.google.com/"
        case "WhatsApp": address = "https://web.whatsapp.com/"
        case "Discord": address = "https://discord.com/channels/@me"
        case "Slack": address = "https://app.slack.com/"
        case "LinkedIn": address = "https://www.linkedin.com/messaging/"
        default: return nil
        }
        return URL(string: address)
    }

    public static func nativeURL(for app: String) -> URL? {
        app == "WhatsApp" ? URL(string: "whatsapp://") : nil
    }
}


public struct PersonMatchPreview: Identifiable {
    public var id: Int64 { observationID }
    public let observationID: Int64
    public let app: String
    public let title: String
    public let personID: String
    public let personName: String
    public let existingCount: Int
}

public struct PersonMatchRule: Identifiable {
    public let id: String
    public let app: String
    public let title: String
    public let hasConflict: Bool
}
