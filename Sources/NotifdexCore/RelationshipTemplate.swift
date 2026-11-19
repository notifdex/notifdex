import Foundation

public enum RelationshipTemplateError: Error, Equatable, CustomStringConvertible {
    case invalidDefinition
    case versionConflict
    case versionNotInstalled
    case assignmentConflict
    case noAssignment
    case unknownStage
    case unknownMilestone

    public var description: String {
        switch self {
        case .invalidDefinition: return "This template definition is invalid."
        case .versionConflict: return "A different definition already uses this template ID and version."
        case .versionNotInstalled: return "Install this template version before applying it."
        case .assignmentConflict: return "This person already has a different template or version."
        case .noAssignment: return "This person has no template."
        case .unknownStage: return "This stage does not belong to the assigned template."
        case .unknownMilestone: return "This milestone does not belong to the assigned template."
        }
    }
}

public struct RelationshipTemplate: Equatable {
    public struct Step: Codable, Equatable, Identifiable {
        public let id: String
        public let name: String
    }

    private struct Definition: Codable, Equatable {
        let id: String
        let version: Int
        let name: String
        let stages: [Step]
        let milestones: [Step]
    }

    private let definition: Definition
    public var id: String { definition.id }
    public var version: Int { definition.version }
    public var name: String { definition.name }
    public var stages: [Step] { definition.stages }
    public var milestones: [Step] { definition.milestones }

    public static func decode(_ data: Data) throws -> Self {
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["id", "version", "name", "stages", "milestones"],
              let stages = fields["stages"] as? [[String: Any]],
              let milestones = fields["milestones"] as? [[String: Any]],
              (stages + milestones).allSatisfy({ Set($0.keys) == ["id", "name"] }) else {
            throw RelationshipTemplateError.invalidDefinition
        }
        let value = try JSONDecoder().decode(Definition.self, from: data)
        guard isID(value.id), (1...Int(Int32.max)).contains(value.version), isName(value.name),
              !value.stages.isEmpty, validSteps(value.stages), validSteps(value.milestones) else {
            throw RelationshipTemplateError.invalidDefinition
        }
        return Self(definition: value)
    }

    public static func bundledFounderOutreach() throws -> Self {
        let name = "founder-outreach-v1"
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "templates")
                ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "templates") else {
            throw StoreError(description: "Missing bundled Founder Outreach template.")
        }
        return try decode(Data(contentsOf: url))
    }

    func encodedDefinition() throws -> String {
        String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
    }

    private static func validSteps(_ steps: [Step]) -> Bool {
        Set(steps.map(\.id)).count == steps.count && steps.allSatisfy { isID($0.id) && isName($0.name) }
    }

    private static func isID(_ value: String) -> Bool {
        value.range(of: "\\A[a-z0-9]+(-[a-z0-9]+)*\\z", options: .regularExpression) != nil
    }

    private static func isName(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct RelationshipTemplateAssignment: Equatable {
    public let definition: RelationshipTemplate
    public let stageID: String
    public let completedMilestones: Set<String>
}
