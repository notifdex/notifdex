import Foundation

public struct InboxQuery: Equatable {
    public enum Scope: Equatable {
        case inbox(app: String?, saved: Bool)
        case person(String)
        case followUps
    }

    public var scope: Scope
    public var search: String
    public var limit: Int

    public init(scope: Scope = .inbox(app: nil, saved: false), search: String = "", limit: Int = 50) {
        self.scope = scope
        self.search = search
        self.limit = limit
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
}

public struct RolodexPerson: Identifiable, Equatable {
    public let id: String
    public let name: String
}

public struct RolodexIdentity: Identifiable, Equatable {
    public let id: String
    public let platform: String
    public let identifier: String
}
