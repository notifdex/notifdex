import Foundation

public enum AppWindowWidthClass: String, Equatable, Sendable {
    case wide
    case compact

    public static let compactThreshold: Double = 860

    public init(windowWidth: Double) {
        self = windowWidth < Self.compactThreshold ? .compact : .wide
    }
}

public enum AppWindowOwner: String, Equatable, Sendable {
    case appKitWindowController
    case swiftUIWindowScene
}

public enum AppTitlebarOwner: String, Equatable, Sendable {
    case appKitToolbar
    case swiftUIToolbar
    case manualView
    case both
}

public enum AppTitlebarHitTarget: String, Equatable, Sendable {
    case nativeThemeFrame
    case swiftUIHostingView
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
    public var shouldCheckBoundsRecovery: Bool

    public static let noOp = WindowChromeMutationPlan(
        applyStructuralChrome: false,
        applyTransparency: false,
        transparentWindow: true,
        shouldCheckBoundsRecovery: false
    )

    public init(
        applyStructuralChrome: Bool,
        applyTransparency: Bool,
        transparentWindow: Bool,
        shouldCheckBoundsRecovery: Bool = false
    ) {
        self.applyStructuralChrome = applyStructuralChrome
        self.applyTransparency = applyTransparency
        self.transparentWindow = transparentWindow
        self.shouldCheckBoundsRecovery = shouldCheckBoundsRecovery
    }

    public var mutatesWindow: Bool {
        applyStructuralChrome || applyTransparency
    }
}

/// Platform-independent rectangle in global AppKit screen coordinates (bottom-left origin).
public struct WindowRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func intersection(_ other: WindowRect) -> WindowRect? {
        let left = max(minX, other.minX)
        let right = min(maxX, other.maxX)
        let bottom = max(minY, other.minY)
        let top = min(maxY, other.maxY)
        guard right > left, top > bottom else { return nil }
        return WindowRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

/// Pure multi-monitor placement and offscreen-titlebar recovery policy matching `spec/WindowDrag.tla`.
///
/// Key invariants:
/// - Never mutates window frames while `isDragging == true`.
/// - Never snaps a window horizontally when straddling two connected displays with a reachable titlebar.
/// - Recovers an unreachable/offscreen titlebar onto the nearest connected display's visible frame.
public enum WindowPlacementGeometry {
    public static func titlebarBand(
        for frame: WindowRect,
        titlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight
    ) -> WindowRect {
        let height = min(max(0, titlebarHeight), max(0, frame.height))
        return WindowRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: max(0, frame.width),
            height: height
        )
    }

    public static func hasReachableTitlebar(
        frame: WindowRect,
        visibleScreens: [WindowRect],
        titlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight,
        minimumVisibleWidth: Double = 120,
        minimumVisibleHeight: Double = 20
    ) -> Bool {
        guard frame.width > 0, frame.height > 0, !visibleScreens.isEmpty else { return false }
        let band = titlebarBand(for: frame, titlebarHeight: titlebarHeight)
        let requiredWidth = min(minimumVisibleWidth, band.width)
        let requiredHeight = min(minimumVisibleHeight, band.height)
        return visibleScreens.contains { screen in
            guard let overlap = band.intersection(screen) else { return false }
            return overlap.width >= requiredWidth && overlap.height >= requiredHeight
        }
    }

    public static func recoveredFrame(
        for frame: WindowRect,
        visibleScreens: [WindowRect],
        isDragging: Bool,
        titlebarHeight: Double = AppTitlebarStyle.unifiedCompact.nominalHeight,
        minimumVisibleWidth: Double = 120,
        minimumVisibleHeight: Double = 20
    ) -> WindowRect? {
        guard !isDragging, !visibleScreens.isEmpty else { return nil }
        if hasReachableTitlebar(
            frame: frame,
            visibleScreens: visibleScreens,
            titlebarHeight: titlebarHeight,
            minimumVisibleWidth: minimumVisibleWidth,
            minimumVisibleHeight: minimumVisibleHeight
        ) {
            return nil
        }

        let target = nearestScreen(to: frame, in: visibleScreens)
        let clampedWidth = min(max(1, frame.width), target.width)
        let clampedHeight = min(max(1, frame.height), target.height)
        let clampedX = min(max(frame.minX, target.minX), target.maxX - clampedWidth)
        let clampedY = min(max(frame.minY, target.minY), target.maxY - clampedHeight)
        return WindowRect(x: clampedX, y: clampedY, width: clampedWidth, height: clampedHeight)
    }

    private static func nearestScreen(to frame: WindowRect, in screens: [WindowRect]) -> WindowRect {
        let centerX = frame.midX
        let centerY = frame.midY
        return screens.min { lhs, rhs in
            squaredDistance(fromX: centerX, y: centerY, to: lhs) < squaredDistance(fromX: centerX, y: centerY, to: rhs)
        } ?? screens[0]
    }

    private static func squaredDistance(fromX x: Double, y: Double, to rect: WindowRect) -> Double {
        let clampedX = min(max(x, rect.minX), rect.maxX)
        let clampedY = min(max(y, rect.minY), rect.maxY)
        let dx = x - clampedX
        let dy = y - clampedY
        return dx * dx + dy * dy
    }
}

/// Deterministic state machine guarding `NSWindow` chrome mutations across SwiftUI
/// updates and cross-monitor drags (mirrors `spec/WindowChrome.tla` and `spec/WindowDrag.tla`).
public struct WindowChromeSyncState: Equatable, Sendable {
    public private(set) var attachedWindowID: ObjectIdentifier?
    public private(set) var chromeApplied: Bool = false
    public private(set) var appliedTransparentWindow: Bool?
    public private(set) var desiredTransparentWindow: Bool = true
    public private(set) var isDragging: Bool = false
    public private(set) var draggedSinceMouseDown: Bool = false
    public private(set) var pendingChromeSync: Bool = false
    public private(set) var pendingBoundsRecovery: Bool = false

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
        pendingBoundsRecovery = false
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
        pendingBoundsRecovery = false
    }

    public mutating func mouseDown() {
        draggedSinceMouseDown = false
    }

    public mutating func beginDrag() {
        isDragging = true
        draggedSinceMouseDown = true
    }

    /// Returns `true` when it is safe to check/recover offscreen window bounds immediately,
    /// or `false` when a drag is active (deferring recovery until `endDrag()`).
    public mutating func noteDisplayReconfiguration() -> Bool {
        if isDragging {
            pendingBoundsRecovery = true
            return false
        }
        pendingBoundsRecovery = false
        return true
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
        let shouldRecoverBounds = pendingBoundsRecovery || wasDragging
        isDragging = false
        pendingBoundsRecovery = false
        guard wasDragging, attachedWindowID != nil else { return .noOp }

        let needsStructural = !chromeApplied
        let needsTransparency = appliedTransparentWindow != desiredTransparentWindow
        pendingChromeSync = false
        guard needsStructural || needsTransparency else {
            return WindowChromeMutationPlan(
                applyStructuralChrome: false,
                applyTransparency: false,
                transparentWindow: desiredTransparentWindow,
                shouldCheckBoundsRecovery: shouldRecoverBounds
            )
        }

        chromeApplied = true
        appliedTransparentWindow = desiredTransparentWindow
        return WindowChromeMutationPlan(
            applyStructuralChrome: needsStructural,
            applyTransparency: needsTransparency,
            transparentWindow: desiredTransparentWindow,
            shouldCheckBoundsRecovery: shouldRecoverBounds
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
    public var windowOwner: AppWindowOwner
    public var toolbarOwner: AppTitlebarOwner
    public var titlebarHitTarget: AppTitlebarHitTarget
    public var hostingSizingIsolated: Bool
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
        windowOwner: AppWindowOwner = .appKitWindowController,
        toolbarOwner: AppTitlebarOwner = .appKitToolbar,
        titlebarHitTarget: AppTitlebarHitTarget = .nativeThemeFrame,
        hostingSizingIsolated: Bool = true,
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
        self.windowOwner = windowOwner
        self.toolbarOwner = toolbarOwner
        self.titlebarHitTarget = titlebarHitTarget
        self.hostingSizingIsolated = hostingSizingIsolated
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

    public var usesNativeAppKitWindowDrag: Bool {
        windowOwner == .appKitWindowController
            && toolbarOwner == .appKitToolbar
            && titlebarHitTarget == .nativeThemeFrame
            && hostingSizingIsolated
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
