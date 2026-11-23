import Foundation
import XCTest
import NotifdexCore
@testable import NotifdexMac

#if os(macOS)
final class RecoveryAutomationTests: XCTestCase {
    func testIsClockControlMatchesLegacyIdentifierAndModernMenuBarItems() {
        XCTAssertTrue(RecoveryAutomation.isClockControl(
            identifier: "com.apple.menuextra.clock", description: "", title: "", role: "", subrole: ""
        ))
        XCTAssertTrue(RecoveryAutomation.isClockControl(
            identifier: "Clock", description: "Sun Nov 22 11:00 PM", title: "", role: "AXMenuBarItem", subrole: "AXMenuExtra"
        ))
        XCTAssertTrue(RecoveryAutomation.isClockControl(
            identifier: "", description: "Clock", title: "", role: "AXMenuBarItem", subrole: ""
        ))
        XCTAssertFalse(RecoveryAutomation.isClockControl(
            identifier: "com.apple.menuextra.wifi", description: "Wi-Fi", title: "Wi-Fi", role: "AXMenuBarItem", subrole: "AXMenuExtra"
        ))
        XCTAssertFalse(RecoveryAutomation.isClockControl(
            identifier: "Clock", description: "Clock", title: "Clock", role: "AXStaticText", subrole: ""
        ))
    }

    func testMatchingStackAppStripsDirectionMarks() {
        let allowed: Set<String> = ["WhatsApp", "X"]
        XCTAssertEqual(
            RecoveryAutomation.matchingStackApp(description: "\u{200E}WhatsApp, 3 notifications", allowedApps: allowed),
            "WhatsApp"
        )
        XCTAssertEqual(
            RecoveryAutomation.matchingStackApp(description: "\u{200F}X 2 notifications", allowedApps: allowed),
            "X"
        )
        XCTAssertNil(
            RecoveryAutomation.matchingStackApp(description: "\u{200E}Calendar, 2 notifications", allowedApps: allowed)
        )
    }

    func testAdvanceExpandsDirectionMarkedWhatsAppStackAndSkipsDisabledOrExpanded() throws {
        var expandedIDs: [String] = []
        var scrolled = 0
        var clockPresses: [TimeInterval] = []
        var panelVisible = false

        let driver = RecoveryDriver(
            hasPanelList: { _ in panelVisible },
            pressClock: { timeout in
                clockPresses.append(timeout)
                panelVisible.toggle()
            },
            items: { _ in
                [
                    RecoveryItem(
                        identifier: "disabled-stack",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "Calendar, 2 notifications",
                        expanded: false,
                        frameY: 10,
                        expand: { expandedIDs.append("disabled-stack") }
                    ),
                    RecoveryItem(
                        identifier: "already-open",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "\u{200E}WhatsApp, 4 notifications",
                        expanded: true,
                        frameY: 20,
                        expand: { expandedIDs.append("already-open") }
                    ),
                    RecoveryItem(
                        identifier: "whatsapp-stack",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "\u{200E}WhatsApp, 3 notifications",
                        expanded: false,
                        frameY: 30,
                        expand: { expandedIDs.append("whatsapp-stack") }
                    )
                ]
            },
            scrollDown: { _ in
                scrolled += 1
                return false
            }
        )

        let automation = RecoveryAutomation(driver: driver)
        try automation.begin()
        XCTAssertEqual(clockPresses, [3])

        // First advance expands the collapsed WhatsApp stack.
        XCTAssertNil(try automation.advance(allowedApps: ["WhatsApp"]))
        XCTAssertEqual(expandedIDs, ["whatsapp-stack"])
        XCTAssertEqual(scrolled, 0)

        // Second advance skips already-expanded whatsapp-stack and stops when scroll returns false.
        let done = try automation.advance(allowedApps: ["WhatsApp"])
        XCTAssertNotNil(done)
        XCTAssertEqual(scrolled, 1)

        // Finish passes bounded timeout through to clock toggle.
        try automation.finish(timeout: 0.5)
        XCTAssertEqual(clockPresses, [3, 0.5])
        XCTAssertFalse(panelVisible)
    }

    func testAdvanceWaitsUpToThreeTicksWhenPanelListNotYetExposed() throws {
        let driver = RecoveryDriver(
            hasPanelList: { _ in false },
            pressClock: { _ in },
            items: { _ in [] },
            scrollDown: { _ in false }
        )
        let automation = RecoveryAutomation(driver: driver)
        try automation.begin()
        XCTAssertNil(try automation.advance(allowedApps: ["X"]))
        XCTAssertNil(try automation.advance(allowedApps: ["X"]))
        let message = try automation.advance(allowedApps: ["X"])
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("No retained notification list") == true)
    }
}
#endif
