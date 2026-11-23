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
    boundMessaging(element)
    var names: CFArray?
    let result = AXUIElementCopyActionNames(element, &names)
    guard result == .success else { throw CaptureError(description: "Could not inspect navigation actions (\(result.rawValue))") }
    return names as? [String] ?? []
}

func perform(_ action: String, on element: AXUIElement) throws {
    guard try actionNames(element).contains(action) else {
        throw CaptureError(description: "Navigation action \(action) is unavailable")
    }
    boundMessaging(element)
    let result = AXUIElementPerformAction(element, action as CFString)
    guard result == .success else { throw CaptureError(description: "Navigation action failed (\(result.rawValue))") }
}

protocol RecoverySession: AnyObject {
    func begin() throws
    func advance(allowedApps: Set<String>) throws -> String?
    func finish(timeout: TimeInterval) throws
}

struct RecoveryItem {
    let identifier: String
    let subrole: String
    let description: String
    let expanded: Bool
    let frameY: CGFloat?
    let expand: () throws -> Void
}

struct RecoveryDriver {
    var hasPanelList: (_ timeout: TimeInterval) throws -> Bool
    var pressClock: (_ timeout: TimeInterval) throws -> Void
    var items: (_ deadline: Date) throws -> [RecoveryItem]
    var scrollDown: (_ deadline: Date) throws -> Bool

    static func live() -> RecoveryDriver {
        func root(bundleID: String) throws -> AXUIElement {
            guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                throw CaptureError(description: "System notification controls are unavailable")
            }
            let element = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.5)
            return element
        }

        func panelList(timeout: TimeInterval) throws -> AXUIElement? {
            let limit = Date().addingTimeInterval(timeout)
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

        func menuBarContainers(for app: AXUIElement) throws -> [AXUIElement] {
            var containers: [AXUIElement] = []
            for attribute in ["AXExtrasMenuBar", "AXMenuBar"] {
                if let bar = axElement(try ax(app, attribute)) {
                    containers.append(bar)
                }
            }
            if containers.isEmpty, let children = try ax(app, "AXChildren") as? [AXUIElement] {
                for child in children {
                    if (try? string(child, "AXRole")) == "AXMenuBar" {
                        containers.append(child)
                    }
                }
            }
            return containers
        }

        func pressClockAction(timeout: TimeInterval) throws {
            let limit = Date().addingTimeInterval(timeout)
            var foundAnyContainer = false
            var controlCenterRoot: AXUIElement?
            for bundleID in ["com.apple.controlcenter", "com.apple.systemuiserver"] {
                guard let app = try? root(bundleID: bundleID) else { continue }
                if bundleID == "com.apple.controlcenter" { controlCenterRoot = app }
                let containers = (try? menuBarContainers(for: app)) ?? []
                if containers.isEmpty { continue }
                foundAnyContainer = true
                for menu in containers {
                    for node in try descendants(menu, deadline: limit) {
                        guard Date() < limit else { throw CaptureError(description: "Clock inspection deadline reached") }
                        let identifier = (try? string(node, "AXIdentifier")) ?? ""
                        let description = (try? string(node, "AXDescription")) ?? ""
                        let title = (try? string(node, "AXTitle")) ?? ""
                        let role = (try? string(node, "AXRole")) ?? ""
                        let subrole = (try? string(node, "AXSubrole")) ?? ""
                        if RecoveryAutomation.isClockControl(
                            identifier: identifier,
                            description: description,
                            title: title,
                            role: role,
                            subrole: subrole
                        ) {
                            try perform("AXPress", on: node)
                            return
                        }
                    }
                }
            }
            if !foundAnyContainer {
                if controlCenterRoot == nil {
                    _ = try root(bundleID: "com.apple.controlcenter")
                }
                var attrsSummary = ""
                if let app = controlCenterRoot {
                    boundMessaging(app)
                    var names: CFArray?
                    if AXUIElementCopyAttributeNames(app, &names) == .success,
                       let list = names as? [String], !list.isEmpty {
                        attrsSummary = " (Control Center attributes: \(list.prefix(8).joined(separator: ", ")))"
                    }
                }
                throw CaptureError(description: "Menu bar clock controls were not exposed\(attrsSummary)")
            }
            throw CaptureError(description: "Could not locate the menu bar clock")
        }

        func scrollDownAction(from list: AXUIElement, deadline: Date) throws -> Bool {
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
                        boundMessaging(bar)
                        var settable = DarwinBoolean(false)
                        guard AXUIElementIsAttributeSettable(bar, "AXValue" as CFString, &settable) == .success,
                              settable.boolValue else { return false }
                        let minimum = (try ax(bar, "AXMinValue") as? NSNumber)?.doubleValue ?? 0
                        let maximum = (try ax(bar, "AXMaxValue") as? NSNumber)?.doubleValue ?? 1
                        guard maximum > minimum, value.doubleValue < maximum else { return false }
                        let next = min(maximum, value.doubleValue + (maximum - minimum) * 0.2)
                        boundMessaging(bar)
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

        return RecoveryDriver(
            hasPanelList: { timeout in try panelList(timeout: timeout) != nil },
            pressClock: { timeout in try pressClockAction(timeout: timeout) },
            items: { deadline in
                guard let list = try panelList(timeout: 3) else { return [] }
                let nodes = try descendants(list, deadline: deadline)
                var result: [RecoveryItem] = []
                for node in nodes {
                    guard Date() < deadline else { break }
                    let subrole = try string(node, "AXSubrole")
                    guard subrole.hasPrefix("AXNotificationCenter") else { continue }
                    let identifier = try string(node, "AXIdentifier")
                    var y: CGFloat?
                    if let raw = try ax(node, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() {
                        let value = raw as! AXValue
                        var frame = CGRect.zero
                        if AXValueGetValue(value, .cgRect, &frame) { y = frame.origin.y }
                    }
                    let expanded = (try ax(node, "AXExpanded") as? NSNumber)?.boolValue ?? false
                    let description = subrole == "AXNotificationCenterBannerStack"
                        ? (try string(node, "AXAttributedDescription"))
                        : ""
                    result.append(RecoveryItem(
                        identifier: identifier,
                        subrole: subrole,
                        description: description,
                        expanded: expanded,
                        frameY: y,
                        expand: { try perform("AXPress", on: node) }
                    ))
                }
                return result
            },
            scrollDown: { deadline in
                guard let list = try panelList(timeout: 3) else { return false }
                return try scrollDownAction(from: list, deadline: deadline)
            }
        )
    }
}

/// Owns a bounded navigation session. Individual notification actions are never invoked.
final class RecoveryAutomation: RecoverySession {
    private let driver: RecoveryDriver
    private var openedPanel = false
    private var budget = RecoveryBudget()
    private var deadline = Date.distantPast
    private var listWaits = 0
    private var expandedStackIDs: Set<String> = []

    init(driver: RecoveryDriver = .live()) {
        self.driver = driver
    }

    static func isClockControl(identifier: String, description: String, title: String,
                               role: String, subrole: String) -> Bool {
        if identifier == "com.apple.menuextra.clock" { return true }
        let isMenuItem = role == "AXMenuBarItem" || subrole == "AXMenuExtra" || role == "AXButton"
        guard isMenuItem else { return false }
        let trimmedID = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmedID == "clock" || trimmedID.contains("menuextra.clock") || trimmedID.hasSuffix(".clock") {
            return true
        }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDescription.caseInsensitiveCompare("Clock") == .orderedSame { return true }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.caseInsensitiveCompare("Clock") == .orderedSame
    }

    static func matchingStackApp(description: String, allowedApps: Set<String>) -> String? {
        // Strip leading direction marks (e.g., U+200E before WhatsApp) before matching.
        let normalized = Observation.normalizedAppLabel(description)
        return allowedApps.sorted { $0.count > $1.count }.first { app in
            normalized == app || normalized.hasPrefix(app + ", ") || normalized.hasPrefix(app + " ")
        }
    }

    func begin() throws {
        deadline = Date().addingTimeInterval(20)
        if try !driver.hasPanelList(3) {
            try driver.pressClock(3)
            openedPanel = true
        }
    }

    /// Returns a completion reason, or nil while another bounded step is needed.
    func advance(allowedApps: Set<String>) throws -> String? {
        guard Date() < deadline, budget.canContinue else {
            return "Recovery reached its navigation limit. Coverage remains unknown."
        }
        guard try driver.hasPanelList(3) else {
            listWaits += 1
            if listWaits < 3 { return nil }
            return "No retained notification list was exposed. History may be empty or unavailable."
        }
        listWaits = 0
        let items = try driver.items(deadline)
        var viewportMarks: [String] = []
        for item in items {
            guard Date() < deadline else { return "Recovery reached its time limit. Coverage remains unknown." }
            var mark = item.identifier
            if let y = item.frameY { mark += ":" + String(format: "%.1f", y) }
            viewportMarks.append(mark)
        }
        // Include unselected app rows and their positions so traversing pages of
        // other apps still counts as progress toward selected apps farther down.
        let fingerprint = viewportMarks.sorted().joined(separator: "|")
        for item in items {
            guard Date() < deadline else { return "Recovery reached its time limit. Coverage remains unknown." }
            guard item.subrole == "AXNotificationCenterBannerStack" else { continue }
            guard !item.identifier.isEmpty, !expandedStackIDs.contains(item.identifier) else { continue }
            if item.expanded { continue }
            guard let app = Self.matchingStackApp(description: item.description, allowedApps: allowedApps),
                  RecoveryPolicy.canExpand(subrole: item.subrole, app: app, allowed: allowedApps) else { continue }
            try item.expand()
            expandedStackIDs.insert(item.identifier)
            budget.record(fingerprint: fingerprint, expandedStack: true)
            return nil
        }
        budget.record(fingerprint: fingerprint, expandedStack: false)
        guard budget.canContinue else { return "Recovery reached a stable viewport. Coverage remains unknown." }
        guard try driver.scrollDown(deadline) else {
            return "Recovery read the exposed alerts. Further scrolling is unavailable or at its end."
        }
        return nil
    }

    func finish(timeout: TimeInterval = 3) throws {
        // Close only a panel opened here that still exposes the retained list.
        // An empty panel is ambiguous; report it instead of toggling blindly.
        if openedPanel, try driver.hasPanelList(timeout) { try driver.pressClock(timeout) }
        openedPanel = false
    }
}
#endif
