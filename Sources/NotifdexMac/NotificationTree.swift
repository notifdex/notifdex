import Foundation
import NotifdexCore

public struct CaptureError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

func treeDescendants<Node>(_ root: Node, deadline: Date, children: (Node) throws -> [Node]) throws -> [Node] {
    var result: [Node] = []
    var pending: [(Node, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
        guard depth < 30, result.count < 2000, Date() < deadline else {
            throw CaptureError(description: "Accessibility traversal limit reached")
        }
        result.append(node)
        pending.append(contentsOf: try children(node).map { ($0, depth + 1) })
    }
    return result
}

public struct Snapshot {
    public var observations: [Observation] = []
    public var issues: [String] = []
}

private func readBanner<Node>(_ node: Node, source: String, allowedApps: Set<String>, deadline: Date,
                              children: (Node) throws -> [Node],
                              attribute: (Node, String) throws -> String) throws -> Observation? {
    let description = try attribute(node, "AXAttributedDescription")
    var fields: [String: String] = [:]
    for child in try treeDescendants(node, deadline: deadline, children: children) {
        guard Date() < deadline else { throw CaptureError(description: "Banner inspection deadline reached") }
        let identifier = try attribute(child, "AXIdentifier")
        if ["title", "subtitle", "body"].contains(identifier) {
            fields[identifier] = try attribute(child, "AXValue")
        }
    }
    let identifier = try attribute(node, "AXIdentifier")
    let observation = Observation(
        sourceID: source, sourceEventID: identifier,
        capturedAt: Date().timeIntervalSince1970, description: description,
        title: fields["title"] ?? "", subtitle: fields["subtitle"] ?? "",
        body: fields["body"] ?? ""
    )
    guard let app = observation.appLabel else {
        throw CaptureError(description: "Unrecognized banner description; app attribution unavailable")
    }
    guard allowedApps.contains(app) else { return nil }
    guard !identifier.isEmpty else { throw CaptureError(description: "Banner ID unavailable") }
    return observation
}

/// Read-only Notification Center contract. Tests supply fixture nodes; the Mac
/// adapter supplies AX reads for the same attributes.
func scanNotificationTree<Node>(_ windows: [Node], source: String, allowedApps: Set<String>, deadline: Date,
                                children: (Node) throws -> [Node],
                                attribute: (Node, String) throws -> String,
                                inspect: ((Observation, Node) -> Void)? = nil) -> Snapshot {
    var result = Snapshot()
    for window in windows {
        do {
            for node in try treeDescendants(window, deadline: deadline, children: children) {
                guard Date() < deadline else { throw CaptureError(description: "Notification inspection deadline reached") }
                do {
                    let subrole = try attribute(node, "AXSubrole")
                    guard subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterAlert" else { continue }
                    if let observation = try readBanner(node, source: source, allowedApps: allowedApps, deadline: deadline,
                                                        children: children, attribute: attribute) {
                        result.observations.append(observation)
                        inspect?(observation, node)
                    }
                } catch {
                    result.issues.append(String(describing: error))
                }
            }
        } catch {
            result.issues.append(String(describing: error))
        }
    }
    return result
}
