import Foundation
import NotifdexCore

#if os(macOS)
import AppKit
import ApplicationServices
import Darwin

struct CaptureError: Error, CustomStringConvertible {
    let description: String
}

func ax(_ element: AXUIElement, _ field: String) throws -> CFTypeRef? {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, field as CFString, &value)
    if status == .noValue || status == .attributeUnsupported { return nil }
    guard status == .success else {
        throw CaptureError(description: "Accessibility \(field) error \(status.rawValue)")
    }
    return value
}

func string(_ element: AXUIElement, _ field: String) throws -> String {
    let value = try ax(element, field)
    if let attributed = value as? NSAttributedString { return attributed.string }
    return value as? String ?? ""
}

func descendants(_ root: AXUIElement) throws -> [AXUIElement] {
    var result: [AXUIElement] = []
    var pending: [(AXUIElement, Int)] = [(root, 0)]
    while let (node, depth) = pending.popLast() {
        guard depth < 30, result.count < 2000 else {
            throw CaptureError(description: "Accessibility traversal limit reached")
        }
        result.append(node)
        let children = try ax(node, "AXChildren") as? [AXUIElement] ?? []
        pending.append(contentsOf: children.map { ($0, depth + 1) })
    }
    return result
}

func snapshot(source: String, allowedApps: Set<String>) throws -> [Observation] {
    guard AXIsProcessTrusted() else { throw CaptureError(description: "Accessibility permission unavailable") }
    guard let process = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.notificationcenterui"
    ).first else { throw CaptureError(description: "Notification Center unavailable") }
    let root = AXUIElementCreateApplication(process.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.5)
    let windows = try ax(root, "AXWindows") as? [AXUIElement] ?? []
    var observations: [Observation] = []
    for window in windows {
        for node in try descendants(window) {
            let subrole = try string(node, "AXSubrole")
            guard subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterAlert" else { continue }
            let description = try string(node, "AXAttributedDescription")
            var fields: [String: String] = [:]
            for child in try descendants(node) {
                let identifier = try string(child, "AXIdentifier")
                if ["title", "subtitle", "body"].contains(identifier) {
                    fields[identifier] = try string(child, "AXValue")
                }
            }
            let identifier = try string(node, "AXIdentifier")
            let observation = Observation(
                sourceID: source, sourceEventID: identifier,
                capturedAt: Date().timeIntervalSince1970, description: description,
                title: fields["title"] ?? "", subtitle: fields["subtitle"] ?? "",
                body: fields["body"] ?? ""
            )
            guard let app = observation.appLabel else {
                throw CaptureError(description: "Unrecognized banner description; app attribution unavailable")
            }
            guard allowedApps.contains(app) else { continue }
            guard !identifier.isEmpty else { throw CaptureError(description: "Banner ID unavailable") }
            observations.append(observation)
        }
    }
    return observations
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.isEmpty {
        print("Usage: notifdex-capture --db PATH --source DEVICE-ID --app X [--app WhatsApp]")
        print("Captures only named apps. Source must stay stable for this Mac and login.")
        return
    }
    guard args.count % 2 == 0 else { throw CaptureError(description: "Options require values") }
    var options: [String: [String]] = [:]
    for index in stride(from: 0, to: args.count, by: 2) {
        guard ["--db", "--source", "--app"].contains(args[index]) else {
            throw CaptureError(description: "Unknown option")
        }
        options[args[index], default: []].append(args[index + 1])
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
    var lastPoll = Date().timeIntervalSince1970
    var lastState = ""
    while !stopped {
        if let error = lifecycleError { throw error }
        let now = Date().timeIntervalSince1970
        if now - lastPoll > 3 || now < lastPoll {
            try store.openGap(runID: runID, reason: "poll_interruption", at: min(now, lastPoll))
        }
        lastPoll = now
        if !sleeping {
            do {
                let observations = try snapshot(source: device + ":notificationcenter", allowedApps: Set(appNames))
                for observation in observations {
                    if try store.record(observation, runID: runID) { print("Saved an observation.") }
                }
                let completedAt = Date().timeIntervalSince1970
                try store.heartbeat(runID: runID, at: completedAt)
                try store.recover(runID: runID, at: completedAt)
                if lastState != "scanning" {
                    print("Scanning accessible alerts. Delivery completeness remains unknown.")
                    lastState = "scanning"
                }
            } catch let error as CaptureError {
                try store.openGap(runID: runID, reason: "accessibility_unavailable", at: now)
                if lastState != error.description { print(error.description); lastState = error.description }
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    try store.finishRun(runID: runID, at: Date().timeIntervalSince1970)
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
