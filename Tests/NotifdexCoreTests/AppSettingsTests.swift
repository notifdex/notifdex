import Foundation
import XCTest
@testable import NotifdexCore

final class AppSettingsTests: XCTestCase {
    func testDefaultsEnableOnlyXAndSettingsSurviveRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        let persistence = AppSettingsStore(url: file)
        var settings = try persistence.loadOrCreate(sourceID: "device")
        XCTAssertTrue(settings.allowedLabels.contains("X"))
        XCTAssertFalse(settings.allowedLabels.contains("Slack"))
        settings.apps[0].enabled = false
        settings.paused = true
        try persistence.save(settings)
        let restored = try persistence.loadOrCreate(sourceID: "different-default")
        XCTAssertTrue(restored.paused)
        XCTAssertEqual(restored.sourceID, "device")
        XCTAssertFalse(restored.allowedLabels.contains("X"))
    }

    func testMessagesIsOptInForNewAndExistingSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettingsStore(url: directory.appendingPathComponent("settings.json"))
        let fresh = try store.loadOrCreate(sourceID: "fixture")
        XCTAssertEqual(fresh.apps.first { $0.id == "messages" }?.enabled, false)
        XCTAssertFalse(fresh.allowedLabels.contains("Messages"))

        var legacy = fresh
        legacy.apps.removeAll { $0.id == "messages" }
        legacy.paused = true
        try store.save(legacy)
        let upgraded = try store.loadOrCreate(sourceID: "different")
        XCTAssertEqual(upgraded.sourceID, "fixture")
        XCTAssertTrue(upgraded.paused)
        XCTAssertEqual(upgraded.apps.first { $0.id == "messages" }?.enabled, false)

        try legacy.addCustomApp(label: "Messages")
        try store.save(legacy)
        let custom = try store.loadOrCreate(sourceID: "different")
        XCTAssertEqual(custom.apps.filter { $0.labels.contains("Messages") }.count, 1)
        XCTAssertTrue(custom.allowedLabels.contains("Messages"))
    }

    func testCorruptSettingsAreSurfaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("invalid".utf8).write(to: file)
        XCTAssertThrowsError(try AppSettingsStore(url: file).loadOrCreate(sourceID: "device"))
    }

    func testRecoveryCannotPressIndividualNotificationsOrDisabledStacks() {
        XCTAssertTrue(RecoveryPolicy.canExpand(subrole: "AXNotificationCenterBannerStack", app: "X", allowed: ["X"]))
        XCTAssertFalse(RecoveryPolicy.canExpand(subrole: "AXNotificationCenterBanner", app: "X", allowed: ["X"]))
        XCTAssertFalse(RecoveryPolicy.canExpand(subrole: "AXNotificationCenterBannerStack", app: "Slack", allowed: ["X"]))
        XCTAssertFalse(RecoveryPolicy.canExpand(subrole: "AXButton", app: "X", allowed: ["X"]))
    }

    func testRecoveryBudgetStopsOnRepeatedViewportAndMaximumSteps() {
        var stalled = RecoveryBudget(maximumSteps: 10, maximumUnchanged: 2)
        stalled.record(fingerprint: "a", expandedStack: false)
        stalled.record(fingerprint: "a", expandedStack: false)
        XCTAssertTrue(stalled.canContinue)
        stalled.record(fingerprint: "a", expandedStack: false)
        XCTAssertFalse(stalled.canContinue)

        var changing = RecoveryBudget(maximumSteps: 3, maximumUnchanged: 2)
        for value in ["a", "b", "c"] { changing.record(fingerprint: value, expandedStack: true) }
        XCTAssertFalse(changing.canContinue)
    }
}
