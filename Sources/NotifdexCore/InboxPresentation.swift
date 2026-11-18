public struct InboxPresentation {
    public enum Order: Hashable {
        case recent
        case byApp
    }

    public struct Section {
        public let app: String?
        public let rows: [InboxEntry]
        public let expanded: Bool
    }

    public var order: Order
    private var collapsedApps: Set<String> = []

    public init(order: Order = .recent) { self.order = order }

    public mutating func toggle(_ app: String) {
        if collapsedApps.remove(app) == nil { collapsedApps.insert(app) }
    }

    public func isExpanded(_ app: String) -> Bool {
        order == .recent || !collapsedApps.contains(app)
    }

    /// Keep the selected capture order within each app section.
    public func sections(for rows: [InboxEntry]) -> [Section] {
        guard !rows.isEmpty else { return [] }
        if order == .recent { return [Section(app: nil, rows: rows, expanded: true)] }
        let groups = Dictionary(grouping: rows, by: \.app)
        return groups.keys.sorted().compactMap { app in
            groups[app].map { Section(app: app, rows: $0, expanded: isExpanded(app)) }
        }
    }
}
