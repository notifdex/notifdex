import Foundation

public enum AppWindowWidthClass: String, Equatable, Sendable {
    case wide
    case compact

    public static let compactThreshold: Double = 860

    public init(windowWidth: Double) {
        self = windowWidth < Self.compactThreshold ? .compact : .wide
    }
}

public enum AppTitlebarOwner: String, Equatable, Sendable {
    case swiftUIToolbar
    case manualView
    case both
}

public enum AppTitlebarStyle: String, Equatable, Sendable {
    /// macOS `.unifiedCompact` (~38pt) — matches Chrome / Antigravity compact top bar height.
    case unifiedCompact
    /// macOS `.unified` (~52pt) — taller standard toolbar.
    case unified

    public var nominalHeight: Double {
        switch self {
        case .unifiedCompact: 38
        case .unified: 52
        }
    }
}

/// Mirrors macOS System Settings -> Desktop & Dock -> "Double-click a window's title bar to".
public enum TitlebarDoubleClickAction: String, Equatable, Sendable {
    case zoom
    case minimize
    case none

    public static func resolved(systemSetting: String?) -> TitlebarDoubleClickAction {
        switch systemSetting?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "minimize":
            .minimize
        case "none":
            .none
        default:
            // "Maximize", "Fill", or unset default on macOS maps to zoom.
            .zoom
        }
    }

    public static func isPointInTitlebar(
        locationY: Double,
        windowHeight: Double,
        contentMaxY: Double,
        fallbackTitlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight
    ) -> Bool {
        guard windowHeight > 0 else { return false }
        let threshold: Double
        if contentMaxY > 0 && contentMaxY < windowHeight {
            threshold = contentMaxY
        } else {
            threshold = max(0, windowHeight - fallbackTitlebarHeight)
        }
        return locationY >= threshold && locationY <= windowHeight
    }

    public static func actionForClick(
        clickCount: Int,
        locationY: Double,
        windowHeight: Double,
        contentMaxY: Double,
        hitInteractiveControl: Bool,
        didDrag: Bool = false,
        systemSetting: String?,
        fallbackTitlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight
    ) -> TitlebarDoubleClickAction {
        guard clickCount == 2,
              !hitInteractiveControl,
              !didDrag,
              isPointInTitlebar(
                  locationY: locationY,
                  windowHeight: windowHeight,
                  contentMaxY: contentMaxY,
                  fallbackTitlebarHeight: fallbackTitlebarHeight
              ) else {
            return .none
        }
        return resolved(systemSetting: systemSetting)
    }
}

/// Minimal mutation plan returned by `WindowChromeSyncState` so AppKit never receives
/// redundant structural chrome writes during idle updates or mid-drag monitor transitions.
public struct WindowChromeMutationPlan: Equatable, Sendable {
    public var applyStructuralChrome: Bool
    public var applyTransparency: Bool
    public var transparentWindow: Bool

    public static let noOp = WindowChromeMutationPlan(
        applyStructuralChrome: false,
        applyTransparency: false,
        transparentWindow: true
    )

    public init(applyStructuralChrome: Bool, applyTransparency: Bool, transparentWindow: Bool) {
        self.applyStructuralChrome = applyStructuralChrome
        self.applyTransparency = applyTransparency
        self.transparentWindow = transparentWindow
    }

    public var mutatesWindow: Bool {
        applyStructuralChrome || applyTransparency
    }
}

/// Deterministic state machine guarding `NSWindow` chrome mutations across SwiftUI
/// updates and cross-monitor drags (mirrors `spec/WindowChrome.tla`).
public struct WindowChromeSyncState: Equatable, Sendable {
    public private(set) var attachedWindowID: ObjectIdentifier?
    public private(set) var chromeApplied: Bool = false
    public private(set) var appliedTransparentWindow: Bool?
    public private(set) var desiredTransparentWindow: Bool = true
    public private(set) var isDragging: Bool = false
    public private(set) var draggedSinceMouseDown: Bool = false
    public private(set) var pendingChromeSync: Bool = false

    public init() {}

    public mutating func attach(windowID: ObjectIdentifier, transparentWindow: Bool) -> WindowChromeMutationPlan {
        desiredTransparentWindow = transparentWindow
        if attachedWindowID == windowID && chromeApplied {
            return requestSync(transparentWindow: transparentWindow)
        }
        attachedWindowID = windowID
        isDragging = false
        draggedSinceMouseDown = false
        chromeApplied = true
        appliedTransparentWindow = transparentWindow
        pendingChromeSync = false
        return WindowChromeMutationPlan(
            applyStructuralChrome: true,
            applyTransparency: true,
            transparentWindow: transparentWindow
        )
    }

    public mutating func detach() {
        attachedWindowID = nil
        chromeApplied = false
        appliedTransparentWindow = nil
        isDragging = false
        draggedSinceMouseDown = false
        pendingChromeSync = false
    }

    public mutating func mouseDown() {
        draggedSinceMouseDown = false
    }

    public mutating func beginDrag() {
        isDragging = true
        draggedSinceMouseDown = true
    }

    public mutating func requestSync(transparentWindow: Bool) -> WindowChromeMutationPlan {
        desiredTransparentWindow = transparentWindow
        guard attachedWindowID != nil else { return .noOp }

        if isDragging {
            pendingChromeSync = (appliedTransparentWindow != transparentWindow) || !chromeApplied
            return .noOp
        }

        let needsStructural = !chromeApplied
        let needsTransparency = appliedTransparentWindow != transparentWindow
        guard needsStructural || needsTransparency else {
            pendingChromeSync = false
            return .noOp
        }

        chromeApplied = true
        appliedTransparentWindow = transparentWindow
        pendingChromeSync = false
        return WindowChromeMutationPlan(
            applyStructuralChrome: needsStructural,
            applyTransparency: needsTransparency,
            transparentWindow: transparentWindow
        )
    }

    public mutating func endDrag() -> WindowChromeMutationPlan {
        let wasDragging = isDragging
        isDragging = false
        guard wasDragging, attachedWindowID != nil else { return .noOp }

        let needsStructural = !chromeApplied
        let needsTransparency = appliedTransparentWindow != desiredTransparentWindow
        pendingChromeSync = false
        guard needsStructural || needsTransparency else {
            return .noOp
        }

        chromeApplied = true
        appliedTransparentWindow = desiredTransparentWindow
        return WindowChromeMutationPlan(
            applyStructuralChrome: needsStructural,
            applyTransparency: needsTransparency,
            transparentWindow: desiredTransparentWindow
        )
    }
}

public enum AppSidebarSection: String, CaseIterable, Equatable, Sendable {
    case primary = "Primary"
    case library = "Library"
    case system = "System"
}

public enum AppNavigationDestination: String, CaseIterable, Equatable, Hashable, Sendable {
    case inbox = "Inbox"
    case today = "Today"
    case people = "People"
    case notes = "Notes"
    case docs = "Docs"
    case flagged = "Flagged"
    case saved = "Saved"
    case hidden = "Hidden"
    case apps = "Apps"
    case recovery = "Recovery"

    public var section: AppSidebarSection {
        switch self {
        case .inbox, .today, .people, .notes, .docs:
            .primary
        case .flagged, .saved, .hidden:
            .library
        case .apps, .recovery:
            .system
        }
    }

    public static func destinations(in section: AppSidebarSection) -> [AppNavigationDestination] {
        allCases.filter { $0.section == section }
    }

    public static var allDestinationsAccountedFor: Bool {
        let grouped = AppSidebarSection.allCases.flatMap { destinations(in: $0) }
        return grouped.count == allCases.count && Set(grouped) == Set(allCases)
    }
}

/// Pure, platform-independent window chrome & sidebar specification matching `spec/WindowChrome.tla`.
public struct WindowChromeState: Equatable, Sendable {
    public static let maxTitlebarHeight: Double = 44
    public static let minimumSidebarLabelFontSize: Double = 14
    public static let sidebarLabelFontSize: Double = 14.5
    public static let sidebarWidth: Double = 196

    public var widthClass: AppWindowWidthClass
    public var activeDestination: AppNavigationDestination
    public var toolbarOwner: AppTitlebarOwner
    public var toolbarStyle: AppTitlebarStyle
    public var brandInToolbar: Bool
    public var brandToolbarPillHidden: Bool
    public var statusInSidebarFooter: Bool
    public var appearanceInSidebarFooter: Bool
    public var statusInCompactHeader: Bool
    public var appearanceInCompactHeader: Bool
    public var statusPopoverOpen: Bool
    public var appearancePopoverOpen: Bool
    public var doubleClickAction: TitlebarDoubleClickAction
    public var zoomed: Bool
    public var minimized: Bool

    public static let production = WindowChromeState()

    public init(
        widthClass: AppWindowWidthClass = .wide,
        activeDestination: AppNavigationDestination = .inbox,
        toolbarOwner: AppTitlebarOwner = .swiftUIToolbar,
        toolbarStyle: AppTitlebarStyle = .unifiedCompact,
        brandInToolbar: Bool = true,
        brandToolbarPillHidden: Bool = true,
        statusInSidebarFooter: Bool = true,
        appearanceInSidebarFooter: Bool = true,
        statusInCompactHeader: Bool = true,
        appearanceInCompactHeader: Bool = true,
        statusPopoverOpen: Bool = false,
        appearancePopoverOpen: Bool = false,
        doubleClickAction: TitlebarDoubleClickAction = .zoom,
        zoomed: Bool = false,
        minimized: Bool = false
    ) {
        self.widthClass = widthClass
        self.activeDestination = activeDestination
        self.toolbarOwner = toolbarOwner
        self.toolbarStyle = toolbarStyle
        self.brandInToolbar = brandInToolbar
        self.brandToolbarPillHidden = brandToolbarPillHidden
        self.statusInSidebarFooter = statusInSidebarFooter
        self.appearanceInSidebarFooter = appearanceInSidebarFooter
        self.statusInCompactHeader = statusInCompactHeader
        self.appearanceInCompactHeader = appearanceInCompactHeader
        self.statusPopoverOpen = statusPopoverOpen
        self.appearancePopoverOpen = appearancePopoverOpen
        self.doubleClickAction = doubleClickAction
        self.zoomed = zoomed
        self.minimized = minimized
    }

    public var titlebarHeight: Double {
        if toolbarOwner == .both {
            return AppTitlebarStyle.unified.nominalHeight * 2
        }
        return toolbarStyle.nominalHeight
    }

    public var isHeightBounded: Bool {
        titlebarHeight <= Self.maxTitlebarHeight
    }

    public var controlsOccluded: Bool {
        toolbarOwner == .both
    }

    public var brandVisible: Bool {
        brandInToolbar && !controlsOccluded
    }

    public var hasBrandToolbarBubble: Bool {
        !brandToolbarPillHidden
    }

    public var statusReachable: Bool {
        widthClass == .wide ? statusInSidebarFooter : statusInCompactHeader
    }

    public var appearanceReachable: Bool {
        widthClass == .wide ? appearanceInSidebarFooter : appearanceInCompactHeader
    }

    public var atMostOnePopoverOpen: Bool {
        !(statusPopoverOpen && appearancePopoverOpen)
    }

    public var showsSidebar: Bool {
        widthClass == .wide
    }

    public var showsCompactPicker: Bool {
        widthClass == .compact
    }

    /// The active section is indicated by the LHS sidebar (wide) or the View picker (compact),
    /// never repeated as a separate section heading inside the main panel.
    public var showsMainPanelModeHeading: Bool {
        false
    }

    public var activeModeAlwaysIndicated: Bool {
        showsSidebar || showsCompactPicker
    }

    public var hasDuplicateModeHeading: Bool {
        showsSidebar && showsMainPanelModeHeading
    }

    public mutating func resize(windowWidth: Double) {
        widthClass = AppWindowWidthClass(windowWidth: windowWidth)
    }

    public mutating func selectDestination(_ destination: AppNavigationDestination) {
        activeDestination = destination
    }

    public mutating func toggleStatusPopover() {
        guard statusReachable else { return }
        statusPopoverOpen.toggle()
        if statusPopoverOpen {
            appearancePopoverOpen = false
        }
    }

    public mutating func toggleAppearancePopover() {
        guard appearanceReachable else { return }
        appearancePopoverOpen.toggle()
        if appearancePopoverOpen {
            statusPopoverOpen = false
        }
    }

    public mutating func doubleClickTitlebar(hitInteractiveControl: Bool) {
        guard !controlsOccluded, !minimized, !hitInteractiveControl else { return }
        switch doubleClickAction {
        case .zoom:
            zoomed.toggle()
        case .minimize:
            minimized = true
        case .none:
            break
        }
    }
}
