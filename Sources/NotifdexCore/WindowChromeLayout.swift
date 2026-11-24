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
    public var statusInToolbar: Bool
    public var appearanceInToolbar: Bool
    public var statusPopoverOpen: Bool
    public var appearancePopoverOpen: Bool

    public static let production = WindowChromeState(
        widthClass: .wide,
        activeDestination: .inbox,
        toolbarOwner: .swiftUIToolbar,
        toolbarStyle: .unifiedCompact,
        brandInToolbar: true,
        statusInToolbar: true,
        appearanceInToolbar: true,
        statusPopoverOpen: false,
        appearancePopoverOpen: false
    )

    public init(
        widthClass: AppWindowWidthClass = .wide,
        activeDestination: AppNavigationDestination = .inbox,
        toolbarOwner: AppTitlebarOwner = .swiftUIToolbar,
        toolbarStyle: AppTitlebarStyle = .unifiedCompact,
        brandInToolbar: Bool = true,
        statusInToolbar: Bool = true,
        appearanceInToolbar: Bool = true,
        statusPopoverOpen: Bool = false,
        appearancePopoverOpen: Bool = false
    ) {
        self.widthClass = widthClass
        self.activeDestination = activeDestination
        self.toolbarOwner = toolbarOwner
        self.toolbarStyle = toolbarStyle
        self.brandInToolbar = brandInToolbar
        self.statusInToolbar = statusInToolbar
        self.appearanceInToolbar = appearanceInToolbar
        self.statusPopoverOpen = statusPopoverOpen
        self.appearancePopoverOpen = appearancePopoverOpen
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
        statusInToolbar && !controlsOccluded
    }

    public var appearanceReachable: Bool {
        appearanceInToolbar && !controlsOccluded
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
}
