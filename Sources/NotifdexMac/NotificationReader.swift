import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import ApplicationServices
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
    try treeDescendants(root, deadline: deadline, children: notificationChildren)
}

private func notificationChildren(_ node: AXUIElement) throws -> [AXUIElement] {
    try ax(node, "AXChildren") as? [AXUIElement] ?? []
}

public func snapshot(source: String, allowedApps: Set<String>) throws -> Snapshot {
    try snapshot(source: source, allowedApps: allowedApps, inspect: nil)
}

private func snapshot(source: String, allowedApps: Set<String>,
                      inspect: ((Observation, AXUIElement) -> Void)?) throws -> Snapshot {
    let deadline = Date().addingTimeInterval(5)
    guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
    guard let process = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.notificationcenterui"
    ).first else { throw CaptureError(description: "Notification Center unavailable") }
    let root = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.5)
    let windows = try ax(root, "AXWindows") as? [AXUIElement] ?? []
    return scanNotificationTree(windows, source: source, allowedApps: allowedApps, deadline: deadline,
                                children: notificationChildren, attribute: string, inspect: inspect)
}

/// Screen diagnostics for an explicitly marked test notification. No actions
/// or writes are performed, and attributes on other banners are never printed.
public func probeAccount(app: String, marker: String) throws -> [String]? {
    let labels: Set<String> = app == "X" ? ["X", "Twitter"] : [app]
    var report: [String]?
    let scan = try snapshot(source: "account-probe", allowedApps: labels) { observation, banner in
        guard report == nil,
              [observation.title, observation.subtitle, observation.body].contains(where: { $0.contains(marker) })
        else { return }
        var lines = [
            "Matched \(app) test notification.",
            "title: \(observation.title.debugDescription)",
            "subtitle: \(observation.subtitle.debugDescription)",
            "body: \(observation.body.debugDescription)",
            "banner description: \(observation.accessibilityDescription.debugDescription)"
        ]
        let deadline = Date().addingTimeInterval(3)
        do {
            for (index, node) in try descendants(banner, deadline: deadline).enumerated() {
                guard Date() < deadline else { throw CaptureError(description: "Probe inspection timed out") }
                var names: CFArray?
                boundMessaging(node)
                let status = AXUIElementCopyAttributeNames(node, &names)
                guard status == .success else {
                    lines.append("element \(index): could not list attributes (\(status.rawValue))")
                    continue
                }
                for name in (names as? [String] ?? []).sorted() {
                    guard Date() < deadline else { throw CaptureError(description: "Probe inspection timed out") }
                    do {
                        let value = try string(node, name)
                        if !value.isEmpty { lines.append("element \(index) \(name): \(value.debugDescription)") }
                    } catch {
                        lines.append("element \(index) \(name): unavailable")
                    }
                }
            }
        } catch { lines.append("Partial inspection: \(error)") }
        report = lines
    }
    if report == nil, let issue = scan.issues.first {
        throw CaptureError(description: issue)
    }
    return report
}

#endif
