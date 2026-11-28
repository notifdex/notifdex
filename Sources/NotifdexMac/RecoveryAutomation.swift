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

        func elementFrame(_ node: AXUIElement) -> CGRect? {
            guard let raw = try? ax(node, "AXFrame"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
            let value = raw as! AXValue
            var frame = CGRect.zero
            return AXValueGetValue(value, .cgRect, &frame) ? frame : nil
        }

        func stackDescription(for node: AXUIElement, deadline: Date) -> String {
            for attr in ["AXAttributedDescription", "AXDescription", "AXTitle", "AXLabel"] {
                if let text = try? string(node, attr),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
            // On macOS 26/27, grouped stacks or summary headers may leave the container
            // description blank and expose the app label only on the first visible child banner.
            if let children = try? descendants(node, deadline: min(deadline, Date().addingTimeInterval(0.5))) {
                for child in children.dropFirst().prefix(24) {
                    guard Date() < deadline else { break }
                    let childSubrole = (try? string(child, "AXSubrole")) ?? ""
                    if childSubrole == "AXNotificationCenterBanner" || childSubrole == "AXNotificationCenterAlert" {
                        for attr in ["AXAttributedDescription", "AXDescription", "AXTitle"] {
                            if let text = try? string(child, attr),
                               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                return text
                            }
                        }
                    }
                }
            }
            return ""
        }

        func expandStack(_ node: AXUIElement) throws {
            boundMessaging(node)
            var expandedSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(node, "AXExpanded" as CFString, &expandedSettable) == .success,
               expandedSettable.boolValue {
                boundMessaging(node)
                if AXUIElementSetAttributeValue(node, "AXExpanded" as CFString, kCFBooleanTrue) == .success {
                    return
                }
            }
            let actions = (try? actionNames(node)) ?? []
            if actions.contains("AXPress") {
                try perform("AXPress", on: node)
                return
            }
            if actions.contains("AXShowDefaultUI") {
                try perform("AXShowDefaultUI", on: node)
                return
            }
            try perform("AXPress", on: node)
        }

        func scrollDownAction(from list: AXUIElement, deadline: Date) throws -> Bool {
            var current: AXUIElement? = list
            var scrollArea: AXUIElement?
            for _ in 0..<12 {
                guard Date() < deadline else { return false }
                guard let node = current else { break }
                if try string(node, "AXRole") == "AXScrollArea" {
                    scrollArea = node
                    let areaActions = (try? actionNames(node)) ?? []
                    if areaActions.contains("AXScrollDownByPage") {
                        try perform("AXScrollDownByPage", on: node)
                        return true
                    }
                    if let bar = axElement(try ax(node, "AXVerticalScrollBar")) {
                        if let value = try ax(bar, "AXValue") as? NSNumber {
                            boundMessaging(bar)
                            var settable = DarwinBoolean(false)
                            if AXUIElementIsAttributeSettable(bar, "AXValue" as CFString, &settable) == .success,
                               settable.boolValue {
                                let minimum = (try ax(bar, "AXMinValue") as? NSNumber)?.doubleValue ?? 0
                                let maximum = (try ax(bar, "AXMaxValue") as? NSNumber)?.doubleValue ?? 1
                                if maximum > minimum, value.doubleValue < maximum {
                                    let next = min(maximum, value.doubleValue + (maximum - minimum) * 0.25)
                                    boundMessaging(bar)
                                    let result = AXUIElementSetAttributeValue(bar, "AXValue" as CFString, NSNumber(value: next))
                                    guard result == .success else { throw CaptureError(description: "Notification scrolling failed (\(result.rawValue))") }
                                    return true
                                }
                                return false
                            }
                        }
                        let barActions = (try? actionNames(bar)) ?? []
                        for action in ["AXIncrementPage", "AXIncrement"] where barActions.contains(action) {
                            try perform(action, on: bar)
                            return true
                        }
                    }
                    break
                }
                current = axElement(try ax(node, "AXParent"))
            }

            // Fallback for overlay/SwiftUI scroll views on macOS 26/27 where AXScrollDownByPage
            // and settable AXVerticalScrollBar are absent: ask the first off-screen notification
            // below the scroll viewport to scroll into view via AXScrollToVisible.
            if let area = scrollArea, let viewport = elementFrame(area) {
                let nodes = (try? descendants(list, deadline: min(deadline, Date().addingTimeInterval(1.5)))) ?? []
                let candidates = nodes.compactMap { node -> (AXUIElement, CGFloat)? in
                    guard Date() < deadline else { return nil }
                    let subrole = (try? string(node, "AXSubrole")) ?? ""
                    guard subrole.hasPrefix("AXNotificationCenter") else { return nil }
                    guard let frame = elementFrame(node), frame.maxY > viewport.maxY + 4 else { return nil }
                    return (node, frame.origin.y)
                }.sorted { $0.1 < $1.1 }

                for (candidate, _) in candidates {
                    let actions = (try? actionNames(candidate)) ?? []
                    if actions.contains("AXScrollToVisible") {
                        try perform("AXScrollToVisible", on: candidate)
                        return true
                    }
                }
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
                    let y = elementFrame(node)?.origin.y
                    let expanded = (try ax(node, "AXExpanded") as? NSNumber)?.boolValue ?? false
                    let description = subrole == "AXNotificationCenterBannerStack"
                        ? stackDescription(for: node, deadline: deadline)
                        : ""
                    result.append(RecoveryItem(
                        identifier: identifier,
                        subrole: subrole,
                        description: description,
                        expanded: expanded,
                        frameY: y,
                        expand: { try expandStack(node) }
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
    private static let maxExpandAttemptsPerStack = 2
    private let driver: RecoveryDriver
    private var openedPanel = false
    private var budget = RecoveryBudget()
    private var deadline = Date.distantPast
    private var listWaits = 0
    private var expandAttemptsByKey: [String: Int] = [:]
    private var settledStackKeys: Set<String> = []
    private var lastExpandedKey: String?
    private var lastExpandedFingerprint: String?
    private var expandedApps: [String] = []
    private var scrollSteps = 0

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
        guard !normalized.isEmpty else { return nil }
        let ordered = allowedApps.sorted { $0.count > $1.count }

        // 1. Direct prefix match (standard macOS format: "<App>, N notifications", "<App>: ...", "<App> — ...").
        if let direct = ordered.first(where: { app in
            normalized == app
                || normalized.hasPrefix(app + ", ")
                || normalized.hasPrefix(app + " ")
                || normalized.hasPrefix(app + ":")
                || normalized.hasPrefix(app + " —")
                || normalized.hasPrefix(app + " -")
        }) {
            return direct
        }

        // 2. Summary phrasing seen on macOS 26/27 grouped stacks ("N notifications from <App>").
        let lower = normalized.lowercased()
        for app in ordered {
            let needle = "from " + app.lowercased()
            if let range = lower.range(of: needle) {
                let after = range.upperBound
                if after == lower.endIndex { return app }
                let boundary = lower[after]
                if boundary == "," || boundary == "." || boundary == " " || boundary == ":" || boundary == ")" {
                    return app
                }
            }
        }
        return nil
    }

    private static func stackKey(for item: RecoveryItem, app: String) -> String {
        if !item.identifier.isEmpty { return item.identifier }
        let yBucket = item.frameY.map { String(Int(($0 / 16.0).rounded())) } ?? "na"
        return "anon:\(app.lowercased()):\(yBucket)"
    }

    private func progressSummary(suffix: String) -> String {
        var parts: [String] = []
        if !expandedApps.isEmpty {
            let uniqueApps = Array(Set(expandedApps)).sorted()
            let count = expandedApps.count
            let noun = count == 1 ? "stack" : "stacks"
            parts.append("Expanded \(count) \(noun) (\(uniqueApps.joined(separator: ", ")))")
        }
        if scrollSteps > 0 {
            let noun = scrollSteps == 1 ? "page" : "pages"
            parts.append("scrolled \(scrollSteps) \(noun)")
        }
        if parts.isEmpty { return suffix }
        return parts.joined(separator: ", ") + ". " + suffix
    }

    func begin() throws {
        deadline = Date().addingTimeInterval(45)
        if try !driver.hasPanelList(3) {
            try driver.pressClock(3)
            openedPanel = true
        }
    }

    /// Returns a completion reason, or nil while another bounded step is needed.
    func advance(allowedApps: Set<String>) throws -> String? {
        guard Date() < deadline, budget.canContinue else {
            return progressSummary(suffix: "Recovery reached its navigation limit. Coverage remains unknown.")
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
            guard Date() < deadline else {
                return progressSummary(suffix: "Recovery reached its time limit. Coverage remains unknown.")
            }
            var mark = item.identifier.isEmpty ? "\(item.subrole):\(item.description.prefix(24))" : item.identifier
            if let y = item.frameY { mark += ":" + String(format: "%.1f", y) }
            viewportMarks.append(mark)
        }
        // Include unselected app rows and their positions so traversing pages of
        // other apps still counts as progress toward selected apps farther down.
        let fingerprint = viewportMarks.sorted().joined(separator: "|")
        // If our last stack press visibly changed the viewport (rows shifted or child banners appeared),
        // treat that stack as settled so we never toggle-collapse it if macOS omits AXExpanded.
        if let prevKey = lastExpandedKey, let prevFP = lastExpandedFingerprint, prevFP != fingerprint {
            settledStackKeys.insert(prevKey)
        }
        lastExpandedKey = nil
        lastExpandedFingerprint = nil

        for item in items {
            guard Date() < deadline else {
                return progressSummary(suffix: "Recovery reached its time limit. Coverage remains unknown.")
            }
            guard item.subrole == "AXNotificationCenterBannerStack" else { continue }
            if item.expanded { continue }
            guard let app = Self.matchingStackApp(description: item.description, allowedApps: allowedApps),
                  RecoveryPolicy.canExpand(subrole: item.subrole, app: app, allowed: allowedApps) else { continue }
            let key = Self.stackKey(for: item, app: app)
            guard !settledStackKeys.contains(key) else { continue }
            let attempts = expandAttemptsByKey[key, default: 0]
            guard attempts < Self.maxExpandAttemptsPerStack else { continue }
            try item.expand()
            expandAttemptsByKey[key] = attempts + 1
            lastExpandedKey = key
            lastExpandedFingerprint = fingerprint
            if attempts == 0 {
                expandedApps.append(app)
            }
            budget.record(fingerprint: fingerprint, expandedStack: true)
            return nil
        }
        budget.record(fingerprint: fingerprint, expandedStack: false)
        guard budget.canContinue else {
            return progressSummary(suffix: "Recovery reached a stable viewport. Coverage remains unknown.")
        }
        guard try driver.scrollDown(deadline) else {
            return progressSummary(suffix: "Recovery read the exposed alerts. Further scrolling is unavailable or at its end.")
        }
        scrollSteps += 1
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
