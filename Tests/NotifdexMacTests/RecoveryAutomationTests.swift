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
        XCTAssertEqual(
            RecoveryAutomation.matchingStackApp(description: "3 notifications from X", allowedApps: allowed),
            "X"
        )
        XCTAssertEqual(
            RecoveryAutomation.matchingStackApp(description: "WhatsApp: 5 notifications", allowedApps: allowed),
            "WhatsApp"
        )
        XCTAssertEqual(
            RecoveryAutomation.matchingStackApp(description: "X — 2 unread messages", allowedApps: allowed),
            "X"
        )
        XCTAssertNil(
            RecoveryAutomation.matchingStackApp(description: "3 notifications from Calendar", allowedApps: allowed)
        )
    }

    func testAdvanceRetriesCollapsedStackOnceAndHandlesEmptyIdentifierStacks() throws {
        var xAttempts = 0
        var gmailAttempts = 0
        var panelVisible = true

        let driver = RecoveryDriver(
            hasPanelList: { _ in panelVisible },
            pressClock: { _ in panelVisible.toggle() },
            items: { _ in
                [
                    // Stack with empty AXIdentifier (seen on modern macOS Notification Center)
                    RecoveryItem(
                        identifier: "",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "3 notifications from Gmail",
                        expanded: gmailAttempts >= 1,
                        frameY: 40,
                        expand: { gmailAttempts += 1 }
                    ),
                    // Stack whose first AXPress is swallowed by slide-in animation; opens on retry
                    RecoveryItem(
                        identifier: "x-stack",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "X, 4 notifications",
                        expanded: xAttempts >= 2,
                        frameY: 120,
                        expand: { xAttempts += 1 }
                    )
                ]
            },
            scrollDown: { _ in false }
        )

        let automation = RecoveryAutomation(driver: driver)
        try automation.begin()

        // Step 1: expands empty-ID Gmail stack
        XCTAssertNil(try automation.advance(allowedApps: ["Gmail", "X"]))
        XCTAssertEqual(gmailAttempts, 1)
        XCTAssertEqual(xAttempts, 0)

        // Step 2: attempts X stack (attempt 1, still collapsed)
        XCTAssertNil(try automation.advance(allowedApps: ["Gmail", "X"]))
        XCTAssertEqual(xAttempts, 1)

        // Step 3: retries X stack because it remained collapsed (attempt 2, now expanded)
        XCTAssertNil(try automation.advance(allowedApps: ["Gmail", "X"]))
        XCTAssertEqual(xAttempts, 2)

        // Step 4: both stacks now expanded -> scroll returns false -> completes with app summary
        let summary = try XCTUnwrap(try automation.advance(allowedApps: ["Gmail", "X"]))
        XCTAssertTrue(summary.contains("Gmail"), "Expected expanded app Gmail in summary: \(summary)")
        XCTAssertTrue(summary.contains("X"), "Expected expanded app X in summary: \(summary)")
    }

    func testAdvanceDoesNotToggleCollapseStackWhenViewportChangedEvenIfAXExpandedStaysFalse() throws {
        var pressCount = 0
        let driver = RecoveryDriver(
            hasPanelList: { _ in true },
            pressClock: { _ in },
            items: { _ in
                var list = [
                    RecoveryItem(
                        identifier: "messages-stack",
                        subrole: "AXNotificationCenterBannerStack",
                        description: "Messages, 2 notifications",
                        expanded: false, // simulates macOS omitting AXExpanded
                        frameY: 20,
                        expand: { pressCount += 1 }
                    )
                ]
                if pressCount >= 1 {
                    // Opening the stack revealed child banners (viewport fingerprint changed)
                    list.append(RecoveryItem(
                        identifier: "messages-banner-1",
                        subrole: "AXNotificationCenterBanner",
                        description: "",
                        expanded: false,
                        frameY: 90,
                        expand: {}
                    ))
                }
                return list
            },
            scrollDown: { _ in false }
        )

        let automation = RecoveryAutomation(driver: driver)
        try automation.begin()
        XCTAssertNil(try automation.advance(allowedApps: ["Messages"]))
        XCTAssertEqual(pressCount, 1)

        // Second advance must see the viewport changed and finish without pressing again.
        let done = try automation.advance(allowedApps: ["Messages"])
        XCTAssertNotNil(done)
        XCTAssertEqual(pressCount, 1, "Must not toggle-collapse a stack whose press visibly expanded the viewport")
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
                        expanded: expandedIDs.contains("whatsapp-stack"),
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
