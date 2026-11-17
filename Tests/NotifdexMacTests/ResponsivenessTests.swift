#if os(macOS)
import XCTest
import AppKit
@testable import NotifdexMac
import NotifdexCore

final class ResponsivenessTests: XCTestCase {
    private func pump(_ mode: RunLoop.Mode, until done: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02))
        }
    }

    func testBackgroundUpdatesArriveWhileMenuIsTracking() {
        XCTAssertTrue(Thread.isMainThread)
        var delivered = false
        DispatchQueue.global().async { onAppMainLoop { delivered = true } }
        pump(.eventTracking, until: { delivered })
        XCTAssertTrue(delivered, "Menu tracking must not block capture status delivery")
        // Drain the previous implementation's queued callback before the test ends.
        pump(.default, until: { delivered })
    }

    func testSettingsRequestCompletesEvenBeforeStartup() {
        let worker = CaptureWorker(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var completed = false
        worker.updateSettings({ $0.paused = true }) { completed = true }
        pump(.eventTracking, until: { completed })
        XCTAssertTrue(completed, "An unavailable settings request must not leave the UI waiting forever")
    }

    func testRealWorkerStartsAndUpdatesWhileMenuIsTracking() throws {
        XCTAssertTrue(Thread.isMainThread)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = CaptureSettings(sourceID: "synthetic")
        settings.paused = true
        try AppSettingsStore(url: directory.appendingPathComponent("settings.json")).save(settings)
        let worker = CaptureWorker(directory: directory)
        var ready = false
        var changed = false
        worker.start { state in
            ready = state.ready
            changed = state.settings?.automaticRecovery == false
        }
        pump(.eventTracking, until: { ready })
        XCTAssertTrue(ready, "A real collector must publish startup while a menu is open")
        worker.updateSettings { $0.automaticRecovery = false }
        pump(.eventTracking, until: { changed })
        XCTAssertTrue(changed, "Settings must remain responsive while a menu is open")
        var stopped = false
        worker.stop { stopped = true }
        pump(.modalPanel, until: { stopped })
        XCTAssertTrue(stopped, "Termination must finish in AppKit's modal loop")
        pump(.default, until: { ready && changed })
    }
}
#endif
