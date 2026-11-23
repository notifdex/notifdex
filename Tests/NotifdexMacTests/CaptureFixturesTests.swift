import Foundation
import XCTest
import NotifdexCore
@testable import NotifdexMac

private struct FixtureNode {
    var attributes: [String: String] = [:]
    var children: [FixtureNode] = []
    var stale = false

    static func banner(_ id: String, app: String, title: String, body: String,
                       subrole: String = "AXNotificationCenterBanner") -> FixtureNode {
        FixtureNode(attributes: [
            "AXSubrole": subrole,
            "AXIdentifier": id,
            "AXAttributedDescription": "\(app), \(title), \(body), from iPhone"
        ], children: [
            FixtureNode(attributes: ["AXIdentifier": "title", "AXValue": title]),
            FixtureNode(attributes: ["AXIdentifier": "body", "AXValue": body])
        ])
    }

    static func scan(_ windows: [FixtureNode], apps: Set<String>, source: String = "fixture:notificationcenter") -> Snapshot {
        scanNotificationTree(windows, source: source, allowedApps: apps, deadline: Date().addingTimeInterval(1),
                             children: { node in
            if node.stale { throw CaptureError(description: "Accessibility AXChildren error -25202") }
            return node.children
        }, attribute: { $0.attributes[$1] ?? "" })
    }
}

final class CaptureFixturesTests: XCTestCase {
    func testSyntheticMessagesBannerRequiresOptIn() {
        let messages = FixtureNode.banner("messages", app: "Messages", title: "Example", body: "Synthetic text")
        let root = FixtureNode(children: [messages])
        XCTAssertTrue(FixtureNode.scan([root], apps: ["X"]).observations.isEmpty)
        let enabled = FixtureNode.scan([root], apps: ["Messages"])
        XCTAssertEqual(enabled.observations.first?.appLabel, "Messages")
        XCTAssertEqual(enabled.observations.first?.body, "Synthetic text")
        XCTAssertTrue(enabled.issues.isEmpty)
    }

    func testWhatsAppBannerWithLeadingDirectionMarkMatchesEnabledApp() {
        let app = "\u{200E}WhatsApp"
        let title = "+1\u{00A0}(555)\u{00A0}010\u{2011}1234"
        let body = "Synthetic WhatsApp message"
        let banner = FixtureNode.banner("whatsapp", app: app, title: title, body: body)
        let scan = FixtureNode.scan([banner], apps: ["WhatsApp"])

        XCTAssertEqual(scan.observations.count, 1)
        XCTAssertEqual(scan.observations.first?.appLabel, "WhatsApp")
        XCTAssertEqual(scan.observations.first?.title, title)
        XCTAssertEqual(scan.observations.first?.accessibilityDescription, "\(app), \(title), \(body), from iPhone")
        XCTAssertTrue(scan.issues.isEmpty)
    }

    func testStaleSiblingDoesNotDiscardGmailAndX() {
        let gmail = FixtureNode.banner("gmail", app: "Gmail", title: "Example", body: "Synthetic Gmail")
        let x = FixtureNode.banner("x", app: "X", title: "Example", body: "Synthetic X", subrole: "AXNotificationCenterAlert")
        let root = FixtureNode(children: [gmail, FixtureNode(stale: true), x])
        let scan = FixtureNode.scan([root], apps: ["Gmail", "X"])
        XCTAssertEqual(Set(scan.observations.map(\.sourceEventID)), ["gmail", "x"])
        XCTAssertEqual(scan.issues.count, 1)
    }

    func testMalformedBannerFromDisabledAppDoesNotCreateFalseScanIssue() {
        let disabledBodyless = FixtureNode(attributes: [
            "AXSubrole": "AXNotificationCenterBanner",
            "AXIdentifier": "cal-1",
            "AXAttributedDescription": "Calendar, Standup"
        ], children: [
            FixtureNode(attributes: ["AXIdentifier": "title", "AXValue": "Standup"])
        ])
        let enabledMalformed = FixtureNode(attributes: [
            "AXSubrole": "AXNotificationCenterBanner",
            "AXIdentifier": "x-bad",
            "AXAttributedDescription": "X, MissingBodyBoundary"
        ], children: [
            FixtureNode(attributes: ["AXIdentifier": "title", "AXValue": "MissingBodyBoundary"])
        ])
        let cleanScan = FixtureNode.scan([disabledBodyless], apps: ["X"])
        XCTAssertTrue(cleanScan.observations.isEmpty)
        XCTAssertTrue(cleanScan.issues.isEmpty)

        let enabledScan = FixtureNode.scan([enabledMalformed], apps: ["X"])
        XCTAssertEqual(enabledScan.issues.count, 1)
    }
}

#if os(macOS)
extension CaptureFixturesTests {
    func testFixtureThroughWorkerDatabaseAndInbox() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = CaptureSettings(sourceID: "fixture")
        settings.automaticRecovery = false
        settings.apps = [
            CaptureApp(id: "x", name: "X", labels: ["X", "Twitter"], enabled: true),
            CaptureApp(id: "gmail", name: "Gmail", labels: ["Gmail"], enabled: true)
        ]
        try AppSettingsStore(url: directory.appendingPathComponent("settings.json")).save(settings)
        let window = FixtureNode(children: [
            FixtureNode.banner("g", app: "Gmail", title: "Sample", body: "Gmail subject"),
            FixtureNode(stale: true),
            FixtureNode.banner("x", app: "X", title: "Sample", body: "X DM"),
            FixtureNode.banner("d", app: "Discord", title: "Sample", body: "Disabled")
        ])
        let worker = CaptureWorker(directory: directory, isTrusted: { true }, readSnapshot: {
            FixtureNode.scan([window], apps: $1, source: $0)
        })
        let first = expectation(description: "both alerts saved")
        let duplicate = expectation(description: "repeat deduplicated")
        var sawFirst = false
        var sawDuplicate = false
        worker.start { state in
            if !sawFirst, state.total == 2 {
                sawFirst = true
                XCTAssertTrue(state.lastScan.contains("New 2"))
                XCTAssertNil(state.recoveryBlocker)
                XCTAssertNotNil(state.lastSavedAt)
                XCTAssertNotNil(state.lastCaptureIssue)
                first.fulfill()
            }
            if sawFirst, !sawDuplicate, state.lastScan.contains("Duplicates 2") {
                sawDuplicate = true
                duplicate.fulfill()
            }
        }
        wait(for: [first, duplicate], timeout: 7)
        let inspected = expectation(description: "inbox is readable")
        worker.withStore({ store in
            (try store.inbox(InboxQuery()), try store.gapCount(reason: "partial_scan"))
        }) { result in
            defer { inspected.fulfill() }
            do {
                let (rows, gaps) = try result.get()
                XCTAssertEqual(Set(rows.map(\.app)), ["Gmail", "X"])
                XCTAssertEqual(Set(rows.map(\.body)), ["Gmail subject", "X DM"])
                XCTAssertEqual(gaps, 1)
            } catch { XCTFail("Inbox query failed: \(error)") }
        }
        wait(for: [inspected], timeout: 3)
        let stopped = expectation(description: "worker stopped")
        worker.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
    }

    func testDeniedPermissionExplainsRecoveryBlockAndDoesNotRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = CaptureWorker(directory: directory, isTrusted: { false }, readSnapshot: { _, _ in
            XCTFail("AX was read without permission")
            return Snapshot()
        })
        let blocked = expectation(description: "permission blocker surfaced")
        var sawBlocker = false
        worker.start { state in
            guard !sawBlocker, state.status == "Accessibility permission needed" else { return }
            sawBlocker = true
            XCTAssertEqual(state.recoveryBlocker, "Grant Accessibility access to Notifdex in System Settings.")
            XCTAssertEqual(state.total, 0)
            blocked.fulfill()
        }
        wait(for: [blocked], timeout: 5)
        let stopped = expectation(description: "worker stopped")
        worker.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
    }

    func testFailedRecoveryBeginPreservesRecoveryGapAcrossCleanLiveScan() throws {
        final class FailingRecovery: RecoverySession {
            func begin() throws { throw CaptureError(description: "Menu bar clock unavailable") }
            func advance(allowedApps: Set<String>) throws -> String? { nil }
            func finish(timeout: TimeInterval) throws {}
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = CaptureSettings(sourceID: "fixture")
        settings.automaticRecovery = true
        settings.apps = [CaptureApp(id: "x", name: "X", labels: ["X"], enabled: true)]
        try AppSettingsStore(url: directory.appendingPathComponent("settings.json")).save(settings)

        let worker = CaptureWorker(
            directory: directory,
            isTrusted: { true },
            readSnapshot: { _, _ in Snapshot() },
            makeRecovery: { FailingRecovery() }
        )
        let sawFailure = expectation(description: "failed recovery surfaces error after live scan")
        var fulfilled = false
        worker.start { state in
            if !fulfilled, state.recoveryStatus.contains("Menu bar clock unavailable"), state.lastScan.contains("Issues 0") {
                fulfilled = true
                XCTAssertEqual(state.error, "Menu bar clock unavailable")
                sawFailure.fulfill()
            }
        }
        wait(for: [sawFailure], timeout: 5)

        let checked = expectation(description: "recovery_navigation gap stays open")
        worker.withStore({ store in
            (try store.openGapCount(), try store.gapCount(reason: "recovery_navigation"))
        }) { result in
            defer { checked.fulfill() }
            do {
                let (openCount, navCount) = try result.get()
                XCTAssertEqual(navCount, 1)
                XCTAssertEqual(openCount, 1, "clean live scan must not erase failed recovery_navigation gap")
            } catch { XCTFail("Store inspect failed: \(error)") }
        }
        wait(for: [checked], timeout: 3)

        let stopped = expectation(description: "worker stopped")
        worker.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 3)
    }

    func testSecondWorkerFailsLockWhileFirstOwnsDatabaseAndSucceedsAfterStop() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = CaptureWorker(directory: directory, isTrusted: { false }, readSnapshot: { _, _ in Snapshot() })
        let firstReady = expectation(description: "first worker ready")
        var gotFirst = false
        first.start { state in
            if !gotFirst, state.ready {
                gotFirst = true
                firstReady.fulfill()
            }
        }
        wait(for: [firstReady], timeout: 5)

        let second = CaptureWorker(directory: directory, isTrusted: { false }, readSnapshot: { _, _ in Snapshot() })
        let lockDenied = expectation(description: "second worker blocked by flock")
        var gotDenied = false
        second.start { state in
            if !gotDenied, !state.ready, state.error?.contains("Another collector is running") == true {
                gotDenied = true
                lockDenied.fulfill()
            }
        }
        wait(for: [lockDenied], timeout: 5)

        let firstStopped = expectation(description: "first stopped")
        first.stop { firstStopped.fulfill() }
        wait(for: [firstStopped], timeout: 3)

        let secondReady = expectation(description: "second acquires lock after first stops")
        var gotSecond = false
        second.start { state in
            if !gotSecond, state.ready {
                gotSecond = true
                secondReady.fulfill()
            }
        }
        wait(for: [secondReady], timeout: 5)

        let secondStopped = expectation(description: "second stopped")
        second.stop { secondStopped.fulfill() }
        wait(for: [secondStopped], timeout: 3)
    }
}
#endif
