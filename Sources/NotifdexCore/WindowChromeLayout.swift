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
        systemSetting: String?,
        fallbackTitlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight
    ) -> TitlebarDoubleClickAction {
        guard clickCount == 2,
              !hitInteractiveControl,
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

    public var widthClass: AppWindowWidthClass
    public var activeDestination: AppNavigationDestination
    public var toolbarOwner: AppTitlebarOwner
    public var toolbarStyle: AppTitlebarStyle
    public var brandInToolbar: Bool
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

    public var statusReachable: Bool {
        widthClass == .wide ? statusInSidebarFooter : statusInCompactHeader
    }

    public var appearanceReachable: Bool {
        widthClass == .wide ? appearanceInSidebarFooter : appearanceInCompactHeader
    }

    public var atMostOnePopoverOpen: Bool {
        !(statusPopoverOpen && appearancePopoverOpen)
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
