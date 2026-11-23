import Foundation
import XCTest
@testable import NotifdexCore

final class AppSettingsTests: XCTestCase {
    func testDefaultsAndSettingsSurviveRelaunch() throws {
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

    func testMessagesDefaultsOnOnlyForNewSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettingsStore(url: directory.appendingPathComponent("settings.json"))
        let fresh = try store.loadOrCreate(sourceID: "fixture")
        XCTAssertEqual(fresh.apps.first { $0.id == "messages" }?.enabled, true)
        XCTAssertEqual(fresh.allowedLabels, ["X", "Twitter", "Messages"])

        var legacy = fresh
        legacy.apps.removeAll { $0.id == "messages" }
        legacy.paused = true
        try store.save(legacy)
        let upgraded = try store.loadOrCreate(sourceID: "different")
        XCTAssertEqual(upgraded.sourceID, "fixture")
        XCTAssertTrue(upgraded.paused)
        XCTAssertEqual(upgraded.apps.first { $0.id == "messages" }?.enabled, false)
        let installed = try XCTUnwrap(upgraded.apps.firstIndex { $0.id == "messages" })
        try store.save(upgraded)
        XCTAssertFalse(try store.loadOrCreate(sourceID: "different").allowedLabels.contains("Messages"))
        var enabled = upgraded
        enabled.apps[installed].enabled = true
        try store.save(enabled)
        XCTAssertTrue(try store.loadOrCreate(sourceID: "different").allowedLabels.contains("Messages"))

        try legacy.addCustomApp(label: "Messages")
        try store.save(legacy)
        let custom = try store.loadOrCreate(sourceID: "different")
        XCTAssertEqual(custom.apps.filter { $0.labels.contains("Messages") }.count, 1)
        XCTAssertTrue(custom.allowedLabels.contains("Messages"))
        legacy.apps[legacy.apps.count - 1].enabled = false
        try store.save(legacy)
        let disabled = try store.loadOrCreate(sourceID: "different")
        XCTAssertEqual(disabled.apps.filter { $0.labels.contains("Messages") }.count, 1)
        XCTAssertFalse(disabled.allowedLabels.contains("Messages"))
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

    func testCustomAppValidationAndSettingsFilePermissions() throws {
        var settings = CaptureSettings(sourceID: "device")
        XCTAssertThrowsError(try settings.addCustomApp(label: "   "))
        XCTAssertThrowsError(try settings.addCustomApp(label: "X"))
        try settings.addCustomApp(label: "  Telegram ")
        XCTAssertTrue(settings.allowedLabels.contains("Telegram"))
        XCTAssertThrowsError(try settings.addCustomApp(label: "Telegram"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try AppSettingsStore(url: file).save(settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }
}
