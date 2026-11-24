import XCTest
@testable import NotifdexCore

final class WindowChromeLayoutTests: XCTestCase {
    func testProductionTitlebarMatchesCompactHeightAndKeepsControlsReachable() {
        var chrome = WindowChromeState.production

        XCTAssertEqual(chrome.toolbarOwner, .swiftUIToolbar)
        XCTAssertEqual(chrome.toolbarStyle, .unifiedCompact)
        XCTAssertEqual(chrome.titlebarHeight, 38)
        XCTAssertTrue(chrome.isHeightBounded, "Titlebar must stay <= 44pt like Chrome/Antigravity")
        XCTAssertFalse(chrome.controlsOccluded)
        XCTAssertTrue(chrome.brandVisible)
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
