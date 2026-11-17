import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import ApplicationServices
public struct CaptureError: Error, CustomStringConvertible {
    public let description: String
    public init(description: String) { self.description = description }
}

// A root element's timeout does not apply to children, even equal elements.
// Apply it to every AX object before attribute/action IPC.
func boundMessaging(_ element: AXUIElement) {
    AXUIElementSetMessagingTimeout(element, 0.5)
}

func ax(_ element: AXUIElement, _ field: String) throws -> CFTypeRef? {
    boundMessaging(element)
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, field as CFString, &value)
    if status == .noValue || status == .attributeUnsupported { return nil }
    guard status == .success else {
        throw CaptureError(description: "Accessibility \(field) error \(status.rawValue)")
    }
    return value
}

func string(_ element: AXUIElement, _ field: String) throws -> String {
    let value = try ax(element, field)
    if let attributed = value as? NSAttributedString { return attributed.string }
    return value as? String ?? ""
}

func descendants(_ root: AXUIElement, deadline: Date = Date().addingTimeInterval(3)) throws -> [AXUIElement] {
    var result: [AXUIElement] = []
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
        guard depth < 30, result.count < 2000, Date() < deadline else {
            throw CaptureError(description: "Accessibility traversal limit reached")
        }
        result.append(node)
        let children = try ax(node, "AXChildren") as? [AXUIElement] ?? []
        pending.append(contentsOf: children.map { ($0, depth + 1) })
    }
    return result
}

public struct Snapshot {
    public var observations: [Observation] = []
    public var issues: [String] = []
}

func readBanner(_ node: AXUIElement, source: String, allowedApps: Set<String>, deadline: Date) throws -> Observation? {
    let description = try string(node, "AXAttributedDescription")
    var fields: [String: String] = [:]
    for child in try descendants(node, deadline: deadline) {
        guard Date() < deadline else { throw CaptureError(description: "Banner inspection deadline reached") }
        let identifier = try string(child, "AXIdentifier")
        if ["title", "subtitle", "body"].contains(identifier) {
            fields[identifier] = try string(child, "AXValue")
        }
    }
    let identifier = try string(node, "AXIdentifier")
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

public func snapshot(source: String, allowedApps: Set<String>) throws -> Snapshot {
    let deadline = Date().addingTimeInterval(5)
    guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
    guard let process = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.notificationcenterui"
    ).first else { throw CaptureError(description: "Notification Center unavailable") }
    let root = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.5)
    let windows = try ax(root, "AXWindows") as? [AXUIElement] ?? []
    var result = Snapshot()
    for window in windows {
        do {
            for node in try descendants(window, deadline: deadline) {
                guard Date() < deadline else { throw CaptureError(description: "Notification inspection deadline reached") }
                do {
                    let subrole = try string(node, "AXSubrole")
                    guard subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterAlert" else { continue }
                    if let observation = try readBanner(node, source: source, allowedApps: allowedApps, deadline: deadline) {
                        result.observations.append(observation)
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

#endif
