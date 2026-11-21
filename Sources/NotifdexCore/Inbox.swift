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
    public var workspaceID: String?

    public init(scope: Scope = .inbox(app: nil, saved: false), search: String = "", limit: Int = 50,
                readFilter: ReadFilter = .all, order: Order = .newestFirst, workspaceID: String? = nil) {
        self.scope = scope
        self.search = search
        self.limit = limit
        self.readFilter = readFilter
        self.order = order
        self.workspaceID = workspaceID
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
    public let titleFiltered: Bool
    public let bodyFiltered: Bool
    public var filtered: Bool { titleFiltered || bodyFiltered }
    public let isRead: Bool
    public let isFlagged: Bool
    public let personRuleID: String?
    public let workspaceID: String?
}

public struct PersonNote: Identifiable {
    public let id: String
    public let title: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct NoteFolder: Identifiable {
    public let id: String
    public let name: String
}

public struct PersonalNote: Identifiable {
    public let id: String
    public let folderID: String?
    public let title: String
    public let body: String
    public let createdAt: Double
    public let updatedAt: Double
}

public struct WorkspaceRecord: Identifiable, Equatable {
    public let id: String
    public let name: String
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


public struct InboxRuleMatch: Equatable {
    public enum Field: String, CaseIterable, Identifiable {
        case title, body
        public var id: String { rawValue }
    }

    public let app: String
    public let field: Field
    public let text: String

    public init(app: String, field: Field, text: String) {
        self.app = app
        self.field = field
        self.text = text
    }

    public static func == (lhs: InboxRuleMatch, rhs: InboxRuleMatch) -> Bool {
        lhs.field == rhs.field && lhs.app.utf8.elementsEqual(rhs.app.utf8)
            && lhs.text.utf8.elementsEqual(rhs.text.utf8)
    }
}

public struct InboxFilter: Identifiable {
    public let id: Int64
    public let match: InboxRuleMatch
    public var app: String { match.app }
    public var subject: String { match.text }
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
