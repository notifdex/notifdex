#if os(macOS)
import AppKit
import SwiftUI

/// Keep the collector in the menu bar while its main window is closed.
@MainActor
struct AppCenterPresence: NSViewRepresentable {
    func makeNSView(context: Context) -> AppCenterPresenceView { AppCenterPresenceView() }

    func updateNSView(_ view: AppCenterPresenceView, context: Context) {}
}

@MainActor
final class AppCenterPresenceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        NSApp.setActivationPolicy(.regular)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
#endif
