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

    func testTitlebarDragZoneExcludesBodyControlsResizeEdgesAndFullScreen() {
        let size = WindowPoint(x: 780, y: 620)
        let contentMaxY = 580.0

        // Empty titlebar middle is draggable.
        XCTAssertTrue(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 350, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        // Below titlebar (main content body) is NOT draggable.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 350, y: 579),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        // Traffic light or toolbar button (interactive control) is NOT draggable.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 40, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: true,
                isFullScreen: false
            )
        )
        // Top resize edge (top 5pt) and left/right resize edges (8pt) stay reserved for resizing.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 350, y: 618),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 4, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 776, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        // Native macOS full-screen windows are never dragged.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 350, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: true
            )
        )
    }

    func testTitlebarDragSessionTracks1To1AcrossThreeMonitorsWithZeroCumulativeDrift() {
        // Exact 3x 1920x1080 monitor layout: Monitor 0 has 30pt menu bar; Monitors 1 & 2 have full 1080 height.
        let screens = [
            WindowRect(x: 0, y: 0, width: 1920, height: 1050),
            WindowRect(x: 1920, y: 0, width: 1920, height: 1080),
            WindowRect(x: 3840, y: 0, width: 1920, height: 1080),
        ]
        let startOrigin = WindowPoint(x: 1920, y: 0)
        let startMouse = WindowPoint(x: 2420, y: 1030)
        var session = TitlebarDragSession(
            startMouse: startMouse,
            startOrigin: startOrigin,
            windowSize: WindowPoint(x: 1920, y: 1050)
        )

        // Sub-threshold 1pt click jitter does not move the window.
        XCTAssertNil(session.updatedOrigin(for: WindowPoint(x: 2421, y: 1030), visibleScreens: screens))
        XCTAssertFalse(session.didMove)

        // Repeated sweeping drags across Monitor 2 -> Monitor 0 -> Monitor 1 -> Monitor 2 must have 0.0 cumulative drift.
        let horizontalOffsets: [Double] = [-100, -500, -1200, -1920, -900, 0, 800, 1600, 1920, 400, -1400, 0]
        for dx in horizontalOffsets {
            let mouse = WindowPoint(x: startMouse.x + dx, y: startMouse.y)
            let updated = session.updatedOrigin(for: mouse, visibleScreens: screens)
            XCTAssertEqual(updated, WindowPoint(x: startOrigin.x + dx, y: 0))
            XCTAssertTrue(session.didMove)
        }

        // Dragging upward on Monitor 2 (visible maxY 1080) works up to 1080, then clamps beneath Monitor 0's 1050 menu bar.
        let liftedOnMonitor2 = session.updatedOrigin(
            for: WindowPoint(x: startMouse.x, y: startMouse.y + 25),
            visibleScreens: screens
        )
        XCTAssertEqual(liftedOnMonitor2, WindowPoint(x: 1920, y: 25))

        let slidOntoMonitor0MenuBar = session.updatedOrigin(
            for: WindowPoint(x: 900, y: startMouse.y + 25),
            visibleScreens: screens
        )
        XCTAssertEqual(
            slidOntoMonitor0MenuBar,
            WindowPoint(x: startOrigin.x + (900 - startMouse.x), y: 0),
            "Crossing onto Monitor 0 must clamp Y beneath the 1050 menu bar without snapping X"
        )
    }

    func testRepeatedBackToBackDragSessionsAcrossThreeMonitorsPreserveExactPositionWithZeroDrift() {
        let screens = [
            WindowRect(x: 0, y: 0, width: 1920, height: 1050),
            WindowRect(x: 1920, y: 0, width: 1920, height: 1080),
            WindowRect(x: 3840, y: 0, width: 1920, height: 1080),
        ]
        let windowSize = WindowPoint(x: 1100, y: 740)
        var currentOrigin = WindowPoint(x: 240, y: 180)

        // Five consecutive grab -> sweep -> release cycles across all three monitors and seams.
        let plannedSessions: [(grabOffsetX: Double, steps: [(dx: Double, dy: Double)])] = [
            // Drag 1: Monitor 0 -> straddling seam 0/1
            (320, [(400, 10), (900, -20), (1320, 0)]),
            // Drag 2: Seam 0/1 -> Monitor 2 -> Monitor 3
            (540, [(600, 30), (1500, 40), (2400, 15)]),
            // Drag 3: Monitor 3 -> straddling seam 2/3 -> back onto Monitor 2
            (280, [(-350, -40), (-900, -20), (-1520, 5)]),
            // Drag 4: Short nudge within Monitor 2
            (600, [(12, -8), (-25, 14), (40, -10)]),
            // Drag 5: Full sweep all the way back to Monitor 0
            (410, [(-800, 0), (-1600, -10), (-2240, 10)]),
        ]

        for (index, plan) in plannedSessions.enumerated() {
            let startMouse = WindowPoint(
                x: currentOrigin.x + plan.grabOffsetX,
                y: currentOrigin.y + windowSize.y - 18
            )
            var session = TitlebarDragSession(
                startMouse: startMouse,
                startOrigin: currentOrigin,
                windowSize: windowSize
            )
            var lastOrigin = currentOrigin
            for step in plan.steps {
                let mouse = WindowPoint(x: startMouse.x + step.dx, y: startMouse.y + step.dy)
                let next = session.updatedOrigin(for: mouse, visibleScreens: screens)
                XCTAssertNotNil(next, "Session \(index + 1) should move for delta \(step)")
                if let next {
                    XCTAssertEqual(
                        next.x,
                        currentOrigin.x + step.dx,
                        accuracy: 0.0001,
                        "Session \(index + 1) must have zero horizontal drift"
                    )
                    lastOrigin = next
                }
            }
            // Release check: titlebar remains reachable, so idle recovery must NOT snap the window.
            let releasedFrame = WindowRect(
                x: lastOrigin.x,
                y: lastOrigin.y,
                width: windowSize.x,
                height: windowSize.y
            )
            XCTAssertNil(
                WindowPlacementGeometry.recoveredFrame(
                    for: releasedFrame,
                    visibleScreens: screens,
                    isDragging: false
                ),
                "Session \(index + 1) release must never snap a visible/straddling window"
            )
            currentOrigin = lastOrigin
        }

        // Net horizontal displacement across all 5 sessions equals the exact sum of final step deltas.
        let expectedFinalX = 240.0 + 1320.0 + 2400.0 - 1520.0 + 40.0 - 2240.0
        XCTAssertEqual(currentOrigin.x, expectedFinalX, accuracy: 0.0001)
    }

    func testTitlebarDragSessionHandlesVerticalAndUnevenDisplayStacksWithoutSnapping() {
        // External ultrawide above a smaller MacBook display with a different X offset and menu bar height.
        let laptop = WindowRect(x: 640, y: 0, width: 1512, height: 945)
        let upperExternal = WindowRect(x: 0, y: 982, width: 3440, height: 1415) // maxY = 2397
        let screens = [laptop, upperExternal]

        let windowSize = WindowPoint(x: 900, y: 620)
        let startOrigin = WindowPoint(x: 800, y: 200)
        let startMouse = WindowPoint(x: 1100, y: 800)
        var session = TitlebarDragSession(
            startMouse: startMouse,
            startOrigin: startOrigin,
            windowSize: windowSize
        )

        // Drag upward onto upper monitor and far left past laptop's X=640 boundary: X must track 1:1 with no clamp.
        let onUpperLeft = session.updatedOrigin(
            for: WindowPoint(x: 300, y: 1800),
            visibleScreens: screens
        )
        XCTAssertEqual(onUpperLeft, WindowPoint(x: 0, y: 1200))

        // Dragging above upperExternal's menu bar (maxY 2397) clamps only Y to 2397 - 620 = 1777, keeping X exact.
        let hitUpperMenuBar = session.updatedOrigin(
            for: WindowPoint(x: 2400, y: 2600),
            visibleScreens: screens
        )
        XCTAssertEqual(hitUpperMenuBar, WindowPoint(x: 2100, y: 1777))

        // Dragging below laptop's bottom (minY 0) clamps only Y so the 38pt titlebar stays reachable (38 - 620 = -582).
        let hitFloor = session.updatedOrigin(
            for: WindowPoint(x: 1200, y: -400),
            visibleScreens: screens
        )
        XCTAssertEqual(hitFloor, WindowPoint(x: 900, y: -582))
    }

    func testTitlebarDragSessionSuppressesMicroJitterAndTracksExactOffsetAfterActivation() {
        let screens = [WindowRect(x: 0, y: 0, width: 1920, height: 1050)]
        let startOrigin = WindowPoint(x: 300, y: 200)
        let startMouse = WindowPoint(x: 600, y: 800)
        var session = TitlebarDragSession(
            startMouse: startMouse,
            startOrigin: startOrigin,
            windowSize: WindowPoint(x: 780, y: 620),
            dragActivationDistance: 2.0
        )

        // Sub-2pt tremor during a click or double-click must not start a drag.
        for jitter in [(0.5, 0.0), (-1.0, 0.5), (1.3, 1.3), (0.0, -1.9)] {
            XCTAssertNil(
                session.updatedOrigin(
                    for: WindowPoint(x: startMouse.x + jitter.0, y: startMouse.y + jitter.1),
                    visibleScreens: screens
                )
            )
            XCTAssertFalse(session.didMove)
        }

        // Crossing 2pt activates the drag and tracks the full exact delta from startMouse (no deadzone offset error).
        let activated = session.updatedOrigin(
            for: WindowPoint(x: startMouse.x + 2.5, y: startMouse.y - 1.0),
            visibleScreens: screens
        )
        XCTAssertTrue(session.didMove)
        XCTAssertEqual(activated, WindowPoint(x: 302.5, y: 199.0))

        // Returning back within 1pt of startMouse after activation STILL updates smoothly back to the exact anchor.
        let returnedNearStart = session.updatedOrigin(
            for: WindowPoint(x: startMouse.x + 0.5, y: startMouse.y),
            visibleScreens: screens
        )
        XCTAssertEqual(returnedNearStart, WindowPoint(x: 300.5, y: 200.0))
    }

    func testTitlebarDragSessionHandlesEmptyScreenListAndMidDragFocusLossCleanup() {
        let startOrigin = WindowPoint(x: 500, y: 150)
        let startMouse = WindowPoint(x: 800, y: 750)
        var session = TitlebarDragSession(
            startMouse: startMouse,
            startOrigin: startOrigin,
            windowSize: WindowPoint(x: 780, y: 620)
        )

        // Empty NSScreen.screens during display wake/reconfiguration must still track 1:1 without crashing.
        let movedWithNoScreens = session.updatedOrigin(
            for: WindowPoint(x: 1150, y: 720),
            visibleScreens: []
        )
        XCTAssertEqual(movedWithNoScreens, WindowPoint(x: 850, y: 120))

        // Mid-drag focus loss (`windowDidResignKey`) calling `endDrag()` flushes both pending transparency and bounds check.
        final class FakeWindowToken {}
        let token = FakeWindowToken()
        var sync = WindowChromeSyncState()
        _ = sync.attach(windowID: ObjectIdentifier(token), transparentWindow: true)
        sync.mouseDown()
        sync.beginDrag()
        XCTAssertFalse(sync.requestSync(transparentWindow: false).mutatesWindow)
        XCTAssertFalse(sync.noteDisplayReconfiguration())
        XCTAssertTrue(sync.pendingChromeSync)
        XCTAssertTrue(sync.pendingBoundsRecovery)

        let resignFlush = sync.endDrag()
        XCTAssertFalse(sync.isDragging)
        XCTAssertFalse(sync.pendingChromeSync)
        XCTAssertFalse(sync.pendingBoundsRecovery)
        XCTAssertTrue(resignFlush.applyTransparency)
        XCTAssertFalse(resignFlush.transparentWindow)
        XCTAssertTrue(resignFlush.shouldCheckBoundsRecovery)
        withExtendedLifetime(token) {}
    }

    func testTitlebarDragZoneRespectsExactResizeBoundariesAndTinyWindows() {
        let size = WindowPoint(x: 780, y: 620)
        let contentMaxY = 582.0

        // Exact inclusive boundaries of the draggable titlebar strip.
        XCTAssertTrue(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 8, y: 582),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        XCTAssertTrue(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 772, y: 615),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        // 1pt outside each boundary is reserved for resizing or content.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 7.9, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 772.1, y: 600),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 350, y: 615.1),
                windowSize: size,
                contentMaxY: contentMaxY,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
        // Degenerate tiny window smaller than horizontal edge insets returns false safely.
        XCTAssertFalse(
            TitlebarDragZone.isInDraggableTitlebar(
                point: WindowPoint(x: 5, y: 10),
                windowSize: WindowPoint(x: 12, y: 20),
                contentMaxY: 0,
                hitInteractiveControl: false,
                isFullScreen: false
            )
        )
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
