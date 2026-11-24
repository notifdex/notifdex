import XCTest
@testable import NotifdexCore

final class WindowChromeLayoutTests: XCTestCase {
    func testProductionTitlebarMatchesCompactHeightAndKeepsControlsVisible() {
        var chrome = WindowChromeState.production

        XCTAssertEqual(chrome.toolbarOwner, .swiftUIToolbar)
        XCTAssertEqual(chrome.toolbarStyle, .unifiedCompact)
        XCTAssertEqual(chrome.titlebarHeight, 38)
        XCTAssertTrue(chrome.isHeightBounded, "Titlebar must stay <= 44pt like Chrome/Antigravity")
        XCTAssertFalse(chrome.controlsOccluded)
        XCTAssertTrue(chrome.brandVisible)
        XCTAssertTrue(chrome.statusReachable)
        XCTAssertTrue(chrome.appearanceReachable)

        // Resizing between compact and wide preserves brand and global toolbar controls.
        for width in [660.0, 780.0, 859.0, 860.0, 1280.0] {
            chrome.resize(windowWidth: width)
            XCTAssertTrue(chrome.brandVisible)
            XCTAssertTrue(chrome.statusReachable)
            XCTAssertTrue(chrome.appearanceReachable)
            XCTAssertTrue(chrome.isHeightBounded)
        }
    }

    func testDoubleTitlebarOwnerRegressionIsDetectedAsOversizedAndOccluded() {
        let broken = WindowChromeState(
            toolbarOwner: .both,
            toolbarStyle: .unified
        )

        XCTAssertEqual(broken.titlebarHeight, 104)
        XCTAssertFalse(broken.isHeightBounded)
        XCTAssertTrue(broken.controlsOccluded)
        XCTAssertFalse(broken.brandVisible)
        XCTAssertFalse(broken.appearanceReachable)
    }

    func testToolbarPopoversAreMutuallyExclusive() {
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
