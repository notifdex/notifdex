import Foundation
import NotifdexCore

#if os(macOS)
import AppKit
import ApplicationServices
import Darwin
import NotifdexMac

func runAccountProbe(_ args: [String]) throws {
    guard args.count == 4, args[0] == "--probe-account", args[2] == "--app",
          ["X", "Gmail"].contains(args[3]), args[1].hasPrefix("NOTIFDEX-"),
          args[1].count > "NOTIFDEX-".count else {
        throw CaptureError(description: "Use --probe-account NOTIFDEX-<test-marker> --app X (or Gmail)")
    }
    let marker = args[1]
    let app = args[3]
    guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
    print("Waiting up to 45 seconds for a \(app) test notification containing \(marker).")
    fflush(stdout)
    let deadline = Date().addingTimeInterval(45)
    var lastIssue: String?
    while Date() < deadline {
        do {
            if let report = try probeAccount(app: app, marker: marker) {
                print(report.joined(separator: "\n"))
                return
            }
        } catch { lastIssue = String(describing: error) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
    if let issue = lastIssue { print("Last scan issue: \(issue)") }
    throw CaptureError(description: "No matching test notification was found. Try again or open its retained alert in Notification Center.")
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.isEmpty {
        print("Usage: notifdex-capture --db PATH --source DEVICE-ID --app X [--app WhatsApp] [--recover] [--diagnostics]")
        print("Captures only named apps. Source must stay stable for this Mac and login.")
        print("--recover: inspect retained accessible alerts for 30 seconds, then exit.")
        print("--diagnostics: show scan counts and matched banner IDs without previews.")
        print("Account probe: notifdex-capture --probe-account NOTIFDEX-<test-marker> --app X (or Gmail)")
        return
    }
    if args.first == "--probe-account" { try runAccountProbe(args); return }
    let recoveryMode = args.contains("--recover")
    let diagnostics = recoveryMode || args.contains("--diagnostics")
    let valueArgs = args.filter { !["--recover", "--diagnostics"].contains($0) }
    guard valueArgs.count % 2 == 0 else { throw CaptureError(description: "Options require values") }
    var options: [String: [String]] = [:]
    for index in stride(from: 0, to: valueArgs.count, by: 2) {
        guard ["--db", "--source", "--app"].contains(valueArgs[index]) else {
            throw CaptureError(description: "Unknown option")
        }
        options[valueArgs[index], default: []].append(valueArgs[index + 1])
    }
    guard let path = options["--db"]?.first, options["--db"]?.count == 1,
          let device = options["--source"]?.first, !device.isEmpty, options["--source"]?.count == 1,
          let appNames = options["--app"], !appNames.isEmpty, !appNames.contains("") else {
        throw CaptureError(description: "Specify one database, one source, and at least one app")
    }

    umask(0o077)
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let directory = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    let lock = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard lock >= 0 else { throw CaptureError(description: "Could not open collector lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw CaptureError(description: "Another collector owns this database")
    }
    let store = try CaptureStore(path: url.path)
    let runID = try store.startRun(at: Date().timeIntervalSince1970)
    var stopped = false
    var sleeping = false
    var lifecycleError: Error?
    let center = NSWorkspace.shared.notificationCenter
    let sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
        sleeping = true
        do { try store.openGap(runID: runID, reason: "sleep", at: Date().timeIntervalSince1970) }
        catch { lifecycleError = error }
    }
    let wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        sleeping = false
    }
    defer { center.removeObserver(sleepObserver); center.removeObserver(wakeObserver) }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { stopped = true }
        source.resume()
        return source
    }
    defer { signals.forEach { $0.cancel() } }

    print("Capture active for \(appNames.joined(separator: ", ")). Ctrl-C stops capture.")
    print("Notification previews will be saved locally. Coverage is best effort.")
    if recoveryMode {
        print("Recovery: open Notification Center now. Expand selected app stacks and scroll through retained alerts.")
        print("This pass runs for 30 seconds. Scanning does not open, dismiss, or expand notifications.")
    }
    let recoveryDeadline = Date().addingTimeInterval(30)
    var savedDuringRecovery = 0
    var maximumObserved = 0
    var successfulScans = 0
    var lastPoll = Date().timeIntervalSince1970
    var lastState = ""
    var lastReport = ""
    while !stopped && (!recoveryMode || Date() < recoveryDeadline) {
        if let error = lifecycleError { throw error }
        let now = Date().timeIntervalSince1970
        if now - lastPoll > 3 || now < lastPoll {
            try store.openGap(runID: runID, reason: "poll_interruption", at: min(now, lastPoll))
        }
        lastPoll = now
        if !sleeping {
            do {
                let scan = try snapshot(source: device + ":notificationcenter", allowedApps: Set(appNames))
                let result = try store.recordBatch(scan.observations, runID: runID, at: Date().timeIntervalSince1970)
                savedDuringRecovery += result.inserted
                maximumObserved = max(maximumObserved, result.observed)
                if scan.issues.isEmpty { successfulScans += 1 }
                if result.inserted > 0 {
                    print("Saved \(result.inserted) observation(s).")
                }
                let report = "Scan: observed=\(result.observed) new=\(result.inserted) duplicates=\(result.duplicates) issues=\(scan.issues.count)"
                // Banner IDs make it possible to verify that a replay was actually read.
                let identifiers = scan.observations.map(\.sourceEventID).sorted().joined(separator: ", ")
                let signature = report + identifiers + scan.issues.joined(separator: "; ")
                if (diagnostics || lastState != "scanning" || result.inserted > 0) && signature != lastReport {
                    print(report)
                    if diagnostics {
                        if !identifiers.isEmpty { print("Observed banner IDs: \(identifiers)") }
                        for issue in Set(scan.issues).sorted() { print("Scan issue: \(issue)") }
                    }
                    lastReport = signature
                }
                let completedAt = Date().timeIntervalSince1970
                if scan.issues.isEmpty {
                    try store.recover(runID: runID, at: completedAt)
                } else {
                    try store.openGap(runID: runID, reason: "partial_scan", at: now)
                    if lastState != "partial_scan" {
                        print("Some alerts could not be read. Use --diagnostics for details.")
                    }
                }
                let state = scan.issues.isEmpty ? "scanning" : "partial_scan"
                if state == "scanning" && lastState != state {
                    print("Scanning accessible alerts. Delivery completeness remains unknown.")
                }
                lastState = state
            } catch let error as CaptureError {
                try store.openGap(runID: runID, reason: "accessibility_unavailable", at: now)
                try store.heartbeat(runID: runID, at: now)
                if lastState != error.description { print(error.description); lastState = error.description }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    try store.finishRun(runID: runID, at: Date().timeIntervalSince1970)
    if recoveryMode {
        print("Recovery ended: new=\(savedDuringRecovery), maximum observed in one scan=\(maximumObserved), error-free scans=\(successfulScans).")
        if maximumObserved == 0 { print("No selected-app alerts were observed. Open and expand their retained notifications, then retry.") }
        print("Cleared, inaccessible, or undelivered history remains unknown.")
    }
    print("Capture stopped.")
}

do { try run() }
catch {
    fputs("Capture stopped with an error: \(error)\n", stderr)
    exit(1)
}
#else
print("Live Accessibility capture requires macOS. Core storage tests can run here.")
#endif
