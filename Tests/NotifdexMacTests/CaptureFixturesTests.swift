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
    func testStaleSiblingDoesNotDiscardGmailAndX() {
        let gmail = FixtureNode.banner("gmail", app: "Gmail", title: "Example", body: "Synthetic Gmail")
        let x = FixtureNode.banner("x", app: "X", title: "Example", body: "Synthetic X", subrole: "AXNotificationCenterAlert")
        let root = FixtureNode(children: [gmail, FixtureNode(stale: true), x])
        let scan = FixtureNode.scan([root], apps: ["Gmail", "X"])
        XCTAssertEqual(Set(scan.observations.map(\.sourceEventID)), ["gmail", "x"])
        XCTAssertEqual(scan.issues.count, 1)
    }
}
