import Foundation
import NotifdexCore
#if os(macOS)
import AppKit
import ApplicationServices

func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func actionNames(_ element: AXUIElement) throws -> [String] {
    var names: CFArray?
    let result = AXUIElementCopyActionNames(element, &names)
    guard result == .success else { throw CaptureError(description: "Could not inspect navigation actions (\(result.rawValue))") }
    return names as? [String] ?? []
}

func perform(_ action: String, on element: AXUIElement) throws {
    guard try actionNames(element).contains(action) else {
        throw CaptureError(description: "Navigation action \(action) is unavailable")
    }
    let result = AXUIElementPerformAction(element, action as CFString)
    guard result == .success else { throw CaptureError(description: "Navigation action failed (\(result.rawValue))") }
}

/// Owns a bounded navigation session. Individual notification actions are never invoked.
final class RecoveryAutomation {
    private var openedPanel = false
    private var budget = RecoveryBudget()
    private var deadline = Date.distantPast
    private var listWaits = 0
    private var expandedStackIDs: Set<String> = []

    private func root(bundleID: String) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw CaptureError(description: "System notification controls are unavailable")
        }
        let element = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private func panelList() throws -> AXUIElement? {
        let limit = Date().addingTimeInterval(3)
        let app = try root(bundleID: "com.apple.notificationcenterui")
        let windows = try ax(app, "AXWindows") as? [AXUIElement] ?? []
        for window in windows {
            for node in try descendants(window, deadline: limit) {
                guard Date() < limit else { throw CaptureError(description: "Panel inspection deadline reached") }
                if try string(node, "AXIdentifier") == "AXNotificationListItems" { return node }
            }
        }
        return nil
    }

    private func pressClock() throws {
        let limit = Date().addingTimeInterval(3)
        let app = try root(bundleID: "com.apple.controlcenter")
        guard let menu = axElement(try ax(app, "AXExtrasMenuBar")) else {
            throw CaptureError(description: "Menu bar clock controls were not exposed")
        }
        for node in try descendants(menu, deadline: limit) {
            guard Date() < limit else { throw CaptureError(description: "Clock inspection deadline reached") }
            if try string(node, "AXIdentifier") == "com.apple.menuextra.clock" {
                try perform("AXPress", on: node)
                return
            }
        }
        throw CaptureError(description: "Could not locate the menu bar clock")
    }

    func begin() throws {
        deadline = Date().addingTimeInterval(20)
        if try panelList() == nil {
            try pressClock()
            openedPanel = true
        }
    }

    /// Returns a completion reason, or nil while another bounded step is needed.
    func advance(allowedApps: Set<String>) throws -> String? {
        guard Date() < deadline, budget.canContinue else {
            return "Recovery reached its navigation limit. Coverage remains unknown."
        }
        guard let list = try panelList() else {
            listWaits += 1
            if listWaits < 3 { return nil }
            return "No retained notification list was exposed. History may be empty or unavailable."
        }
        listWaits = 0
        let nodes = try descendants(list)
        var viewportMarks: [String] = []
        for node in nodes {
            guard Date() < deadline else { return "Recovery reached its time limit. Coverage remains unknown." }
            let subrole = try string(node, "AXSubrole")
            guard subrole.hasPrefix("AXNotificationCenter") else { continue }
            let identifier = try string(node, "AXIdentifier")
            var mark = identifier
            if let raw = try ax(node, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
                let value = raw as! AXValue
                var frame = CGRect.zero
                if AXValueGetValue(value, .cgRect, &frame) { mark += ":" + String(format: "%.1f", frame.origin.y) }
            }
            viewportMarks.append(mark)
        }
        // Include unselected app rows and their positions so traversing pages of
        // other apps still counts as progress toward selected apps farther down.
        let fingerprint = viewportMarks.sorted().joined(separator: "|")
        for node in nodes {
            guard Date() < deadline else { return "Recovery reached its time limit. Coverage remains unknown." }
            let subrole = try string(node, "AXSubrole")
            guard subrole == "AXNotificationCenterBannerStack" else { continue }
            let stackID = try string(node, "AXIdentifier")
            guard !stackID.isEmpty, !expandedStackIDs.contains(stackID) else { continue }
            if let expanded = try ax(node, "AXExpanded") as? NSNumber, expanded.boolValue { continue }
            let description = try string(node, "AXAttributedDescription")
            let app = allowedApps.sorted { $0.count > $1.count }.first {
                description.hasPrefix($0 + ", ") || description.hasPrefix($0 + " ")
            }
            guard let app = app,
                  RecoveryPolicy.canExpand(subrole: subrole, app: app, allowed: allowedApps) else { continue }
            try perform("AXPress", on: node)
            expandedStackIDs.insert(stackID)
            budget.record(fingerprint: fingerprint, expandedStack: true)
            return nil
        }
        budget.record(fingerprint: fingerprint, expandedStack: false)
        guard budget.canContinue else { return "Recovery reached a stable viewport. Coverage remains unknown." }
        guard try scrollDown(from: list) else {
            return "Recovery read the exposed alerts. Further scrolling is unavailable or at its end."
        }
        return nil
    }

    private func scrollDown(from list: AXUIElement) throws -> Bool {
        var current: AXUIElement? = list
        for _ in 0..<12 {
            guard Date() < deadline else { return false }
            guard let node = current else { break }
            if try string(node, "AXRole") == "AXScrollArea" {
                if try actionNames(node).contains("AXScrollDownByPage") {
                    try perform("AXScrollDownByPage", on: node)
                    return true
                }
                if let bar = axElement(try ax(node, "AXVerticalScrollBar")),
                   let value = try ax(bar, "AXValue") as? NSNumber {
                    var settable = DarwinBoolean(false)
                    guard AXUIElementIsAttributeSettable(bar, "AXValue" as CFString, &settable) == .success,
                          settable.boolValue else { return false }
                    let minimum = (try ax(bar, "AXMinValue") as? NSNumber)?.doubleValue ?? 0
                    let maximum = (try ax(bar, "AXMaxValue") as? NSNumber)?.doubleValue ?? 1
                    guard maximum > minimum, value.doubleValue < maximum else { return false }
                    let next = min(maximum, value.doubleValue + (maximum - minimum) * 0.2)
                    let result = AXUIElementSetAttributeValue(bar, "AXValue" as CFString, NSNumber(value: next))
                    guard result == .success else { throw CaptureError(description: "Notification scrolling failed (\(result.rawValue))") }
                    return true
                }
                return false
            }
            current = axElement(try ax(node, "AXParent"))
        }
        return false
    }

    func finish() throws {
        // Close only a panel opened here that still exposes the retained list.
        // An empty panel is ambiguous; report it instead of toggling blindly.
        if openedPanel, try panelList() != nil { try pressClock() }
        openedPanel = false
    }
}
#endif
