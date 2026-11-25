import XCTest
@testable import NotifdexCore

final class WindowChromeLayoutTests: XCTestCase {
    func testProductionTitlebarMatchesCompactHeightAndKeepsControlsReachable() {
        var chrome = WindowChromeState.production

        XCTAssertEqual(chrome.windowOwner, .appKitWindowController)
        XCTAssertEqual(chrome.toolbarOwner, .appKitToolbar)
        XCTAssertEqual(chrome.titlebarHitTarget, .nativeThemeFrame)
        XCTAssertTrue(chrome.hostingSizingIsolated)
        XCTAssertTrue(chrome.usesNativeAppKitWindowDrag)
        XCTAssertEqual(chrome.toolbarStyle, .unifiedCompact)
        XCTAssertEqual(chrome.titlebarHeight, 38)
        XCTAssertTrue(chrome.isHeightBounded, "Titlebar must stay <= 44pt like Chrome/Antigravity")
        XCTAssertFalse(chrome.controlsOccluded)
        XCTAssertTrue(chrome.brandVisible)
        XCTAssertTrue(chrome.brandToolbarPillHidden, "Brand ToolbarItem must hide macOS 26 glass pill bubble")
        XCTAssertFalse(chrome.hasBrandToolbarBubble)
        XCTAssertTrue(chrome.statusInSidebarFooter)
        XCTAssertTrue(chrome.appearanceInSidebarFooter)
        XCTAssertTrue(chrome.statusReachable)
        XCTAssertTrue(chrome.appearanceReachable)
        XCTAssertGreaterThanOrEqual(
            WindowChromeState.sidebarLabelFontSize,
            WindowChromeState.minimumSidebarLabelFontSize
        )
        XCTAssertFalse(chrome.showsMainPanelModeHeading)
        XCTAssertFalse(chrome.hasDuplicateModeHeading)
        XCTAssertTrue(chrome.activeModeAlwaysIndicated)

        for width in [660.0, 780.0, 859.0, 860.0, 1280.0] {
            chrome.resize(windowWidth: width)
            XCTAssertTrue(chrome.brandVisible)
            XCTAssertTrue(chrome.statusReachable)
            XCTAssertTrue(chrome.appearanceReachable)
            XCTAssertTrue(chrome.isHeightBounded)
            XCTAssertTrue(chrome.activeModeAlwaysIndicated)
            XCTAssertFalse(chrome.hasDuplicateModeHeading)
        }
    }

    func testDoubleTitlebarOwnerRegressionIsDetectedAsOversizedAndOccluded() {
        var broken = WindowChromeState(
            toolbarOwner: .both,
            toolbarStyle: .unified
        )

        XCTAssertEqual(broken.titlebarHeight, 104)
        XCTAssertFalse(broken.isHeightBounded)
        XCTAssertTrue(broken.controlsOccluded)
        XCTAssertFalse(broken.brandVisible)

        broken.doubleClickTitlebar(hitInteractiveControl: false)
        XCTAssertFalse(broken.zoomed, "Occluded double-owner titlebar cannot zoom")
    }

    func testTitlebarDoubleClickHonorsSystemSettingAndIgnoresControlsOrBody() {
        XCTAssertEqual(TitlebarDoubleClickAction.resolved(systemSetting: nil), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolved(systemSetting: "Maximize"), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolved(systemSetting: "Fill"), .zoom)
        XCTAssertEqual(TitlebarDoubleClickAction.resolved(systemSetting: "Minimize"), .minimize)
        XCTAssertEqual(TitlebarDoubleClickAction.resolved(systemSetting: "None"), .none)

        // Window height 620, contentLayoutRect.maxY 582 -> top 38pt is the titlebar.
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 2,
                locationY: 600,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: false,
                systemSetting: "Maximize"
            ),
            .zoom
        )
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 2,
                locationY: 600,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: false,
                systemSetting: "Minimize"
            ),
            .minimize
        )
        // Single click never zooms.
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 1,
                locationY: 600,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: false,
                systemSetting: "Maximize"
            ),
            .none
        )
        // Double-click inside main content area (below 582) never zooms.
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 2,
                locationY: 400,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: false,
                systemSetting: "Maximize"
            ),
            .none
        )
        // Double-click on a traffic light or button never zooms.
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 2,
                locationY: 600,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: true,
                systemSetting: "Maximize"
            ),
            .none
        )
        // Releasing a cross-monitor drag (even with clickCount == 2) never zooms or minimizes.
        XCTAssertEqual(
            TitlebarDoubleClickAction.actionForClick(
                clickCount: 2,
                locationY: 600,
                windowHeight: 620,
                contentMaxY: 582,
                hitInteractiveControl: false,
                didDrag: true,
                systemSetting: "Maximize"
            ),
            .none
        )
    }

    func testWindowChromeSyncIsIdempotentWhenIdleAndDefersMutationsDuringCrossMonitorDrag() {
        final class FakeWindowToken {}
        let tokenA = FakeWindowToken()
        let tokenB = FakeWindowToken()
        let windowA = ObjectIdentifier(tokenA)
        let windowB = ObjectIdentifier(tokenB)
        XCTAssertNotEqual(windowA, windowB)

        var sync = WindowChromeSyncState()

        // First attach applies structural chrome and transparency once.
        let initial = sync.attach(windowID: windowA, transparentWindow: true)
        XCTAssertTrue(initial.applyStructuralChrome)
        XCTAssertTrue(initial.applyTransparency)
        XCTAssertTrue(initial.transparentWindow)

        // Repeated SwiftUI updateNSView calls with unchanged state must be no-ops.
        let idleTick = sync.requestSync(transparentWindow: true)
        XCTAssertFalse(idleTick.mutatesWindow, "Idle SwiftUI ticks must not rewrite NSWindow chrome")

        // Changing appearance while idle updates transparency only, never structural chrome.
        let solidSwitch = sync.requestSync(transparentWindow: false)
        XCTAssertFalse(solidSwitch.applyStructuralChrome)
        XCTAssertTrue(solidSwitch.applyTransparency)
        XCTAssertFalse(solidSwitch.transparentWindow)

        // During a cross-monitor drag, SwiftUI updateNSView ticks must NEVER mutate NSWindow chrome.
        sync.mouseDown()
        sync.beginDrag()
        XCTAssertTrue(sync.isDragging)
        XCTAssertTrue(sync.draggedSinceMouseDown)

        let dragTickSame = sync.requestSync(transparentWindow: false)
        XCTAssertFalse(dragTickSame.mutatesWindow)
        XCTAssertFalse(sync.pendingChromeSync)

        let dragTickChanged = sync.requestSync(transparentWindow: true)
        XCTAssertFalse(dragTickChanged.mutatesWindow, "Must defer transparency mutation until drag finishes")
        XCTAssertTrue(sync.pendingChromeSync)

        // Ending the drag flushes the deferred transparency change without re-running structural chrome.
        let flush = sync.endDrag()
        XCTAssertFalse(sync.isDragging)
        XCTAssertFalse(sync.pendingChromeSync)
        XCTAssertFalse(flush.applyStructuralChrome)
        XCTAssertTrue(flush.applyTransparency)
        XCTAssertTrue(flush.transparentWindow)

        // Subsequent idle tick is again a no-op.
        XCTAssertFalse(sync.requestSync(transparentWindow: true).mutatesWindow)

        // Attaching a brand-new NSWindow configures structural chrome once for that window.
        let reattach = sync.attach(windowID: windowB, transparentWindow: true)
        XCTAssertTrue(reattach.applyStructuralChrome)
        XCTAssertTrue(reattach.applyTransparency)
        withExtendedLifetime((tokenA, tokenB)) {}
    }

    func testWindowChromeDoubleClickStateTransitions() {
        var zoomChrome = WindowChromeState(doubleClickAction: .zoom)
        zoomChrome.doubleClickTitlebar(hitInteractiveControl: true)
        XCTAssertFalse(zoomChrome.zoomed)
        zoomChrome.doubleClickTitlebar(hitInteractiveControl: false)
        XCTAssertTrue(zoomChrome.zoomed)
        zoomChrome.doubleClickTitlebar(hitInteractiveControl: false)
        XCTAssertFalse(zoomChrome.zoomed)

        var minimizeChrome = WindowChromeState(doubleClickAction: .minimize)
        minimizeChrome.doubleClickTitlebar(hitInteractiveControl: false)
        XCTAssertTrue(minimizeChrome.minimized)
        XCTAssertFalse(minimizeChrome.zoomed)
    }

    func testPopoversAreMutuallyExclusive() {
        var chrome = WindowChromeState.production

        chrome.toggleStatusPopover()
        XCTAssertTrue(chrome.statusPopoverOpen)
        XCTAssertFalse(chrome.appearancePopoverOpen)
        XCTAssertTrue(chrome.atMostOnePopoverOpen)

        chrome.toggleAppearancePopover()
        XCTAssertFalse(chrome.statusPopoverOpen)
        XCTAssertTrue(chrome.appearancePopoverOpen)
        XCTAssertTrue(chrome.atMostOnePopoverOpen)

        chrome.toggleAppearancePopover()
        XCTAssertFalse(chrome.appearancePopoverOpen)
    }

    func testSwiftUIWindowSceneRegressionIsRejectedByNativeWindowDragPolicy() {
        let brokenScene = WindowChromeState(
            windowOwner: .swiftUIWindowScene,
            toolbarOwner: .swiftUIToolbar,
            titlebarHitTarget: .swiftUIHostingView,
            hostingSizingIsolated: false
        )
        XCTAssertFalse(brokenScene.usesNativeAppKitWindowDrag)
    }

    func testMultiMonitorPlacementNeverSnapsDuringDragOrValidStraddleAndRecoversOffscreen() {
        // Matches a 3x 1920x1080 side-by-side monitor setup where monitor 0 has a 30pt menu bar.
        let screens = [
            WindowRect(x: 0, y: 0, width: 1920, height: 1050),
            WindowRect(x: 1920, y: 0, width: 1920, height: 1080),
            WindowRect(x: 3840, y: 0, width: 1920, height: 1080),
        ]

        // 1. Straddling monitor 0 and monitor 1 is completely valid and must NEVER snap.
        let straddling01 = WindowRect(x: 1500, y: 200, width: 780, height: 620)
        XCTAssertTrue(WindowPlacementGeometry.hasReachableTitlebar(frame: straddling01, visibleScreens: screens))
        XCTAssertNil(WindowPlacementGeometry.recoveredFrame(for: straddling01, visibleScreens: screens, isDragging: false))

        // 2. Straddling monitor 1 and monitor 2 must NEVER snap.
        let straddling12 = WindowRect(x: 3500, y: 200, width: 780, height: 620)
        XCTAssertTrue(WindowPlacementGeometry.hasReachableTitlebar(frame: straddling12, visibleScreens: screens))
        XCTAssertNil(WindowPlacementGeometry.recoveredFrame(for: straddling12, visibleScreens: screens, isDragging: false))

        // 3. Even if completely offscreen, active drags must NEVER trigger programmatic setFrame.
        let offscreenRight = WindowRect(x: 5900, y: 200, width: 780, height: 620)
        XCTAssertFalse(WindowPlacementGeometry.hasReachableTitlebar(frame: offscreenRight, visibleScreens: screens))
        XCTAssertNil(
            WindowPlacementGeometry.recoveredFrame(for: offscreenRight, visibleScreens: screens, isDragging: true),
            "Active drags must never be interrupted by programmatic frame recovery"
        )

        // 4. Once idle (or after a monitor disconnect), an offscreen window recovers onto the nearest display.
        let recoveredRight = WindowPlacementGeometry.recoveredFrame(for: offscreenRight, visibleScreens: screens, isDragging: false)
        XCTAssertEqual(recoveredRight, WindowRect(x: 4980, y: 200, width: 780, height: 620))
        if let recoveredRight {
            XCTAssertTrue(WindowPlacementGeometry.hasReachableTitlebar(frame: recoveredRight, visibleScreens: screens))
        }

        // 5. Window pushed above the menu bar so its titlebar is unreachable recovers beneath visible maxY.
        let aboveMenuBar = WindowRect(x: 200, y: 500, width: 780, height: 620)
        XCTAssertFalse(WindowPlacementGeometry.hasReachableTitlebar(frame: aboveMenuBar, visibleScreens: screens))
        let recoveredTop = WindowPlacementGeometry.recoveredFrame(for: aboveMenuBar, visibleScreens: screens, isDragging: false)
        XCTAssertEqual(recoveredTop, WindowRect(x: 200, y: 430, width: 780, height: 620))

        // 6. Disconnecting external monitors strands a monitor-2 window offscreen; idle recovery brings it onto monitor 0.
        let singleScreen = [WindowRect(x: 0, y: 0, width: 1920, height: 1050)]
        let strandedOnDisconnected = WindowRect(x: 4100, y: 220, width: 780, height: 620)
        let recoveredSingle = WindowPlacementGeometry.recoveredFrame(
            for: strandedOnDisconnected,
            visibleScreens: singleScreen,
            isDragging: false
        )
        XCTAssertEqual(recoveredSingle, WindowRect(x: 1140, y: 220, width: 780, height: 620))
    }

    func testDisplayReconfigurationDuringDragDefersBoundsRecoveryUntilIdle() {
        final class FakeWindowToken {}
        let token = FakeWindowToken()
        var sync = WindowChromeSyncState()
        _ = sync.attach(windowID: ObjectIdentifier(token), transparentWindow: true)

        sync.mouseDown()
        sync.beginDrag()
        XCTAssertFalse(
            sync.noteDisplayReconfiguration(),
            "Display reconfiguration mid-drag must defer bounds recovery until drag ends"
        )
        XCTAssertTrue(sync.pendingBoundsRecovery)

        let endPlan = sync.endDrag()
        XCTAssertFalse(sync.isDragging)
        XCTAssertFalse(sync.pendingBoundsRecovery)
        XCTAssertTrue(endPlan.shouldCheckBoundsRecovery)

        // When idle, display reconfiguration checks bounds immediately.
        XCTAssertTrue(sync.noteDisplayReconfiguration())
        XCTAssertFalse(sync.pendingBoundsRecovery)
        withExtendedLifetime(token) {}
    }

    func testSidebarSectionsAccountForEveryDestinationWithoutDuplicates() {
        XCTAssertTrue(AppNavigationDestination.allDestinationsAccountedFor)
        XCTAssertEqual(
            AppNavigationDestination.destinations(in: .primary),
            [.inbox, .today, .people, .notes, .docs]
        )
        XCTAssertEqual(
            AppNavigationDestination.destinations(in: .library),
            [.flagged, .saved, .hidden]
        )
        XCTAssertEqual(
            AppNavigationDestination.destinations(in: .system),
            [.apps, .recovery]
        )
    }
}
