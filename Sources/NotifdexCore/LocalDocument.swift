public struct DocumentSummary: Identifiable {
    public let id: String
    public let title: String
    public let updatedAt: Double
}

public struct LocalDocument {
    public let title: String
    public let body: String

    public static let maximumBodyBytes = 2 * 1024 * 1024
}
