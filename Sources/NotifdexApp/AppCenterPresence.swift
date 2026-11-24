#if os(macOS)
import AppKit
import SwiftUI

/// Keep the collector in the menu bar while its main window is closed, and
/// configure unified transparent window chrome for glass appearances.
@MainActor
struct AppCenterPresence: NSViewRepresentable {
    var transparentWindow: Bool = true

    func makeNSView(context: Context) -> AppCenterPresenceView {
        let view = AppCenterPresenceView()
        view.transparentWindow = transparentWindow
        return view
    }

    func updateNSView(_ view: AppCenterPresenceView, context: Context) {
        view.transparentWindow = transparentWindow
        view.applyWindowChrome()
    }
}

@MainActor
final class AppCenterPresenceView: NSView {
    static weak var appCenterWindow: NSWindow?
    var transparentWindow: Bool = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        guard let window else { return }
        Self.appCenterWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        applyWindowChrome()
        NSApp.setActivationPolicy(.regular)
    }

    func applyWindowChrome() {
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.toolbarStyle = .unifiedCompact
        window.toolbar?.showsBaselineSeparator = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isOpaque = !transparentWindow
        window.backgroundColor = transparentWindow ? .clear : .windowBackgroundColor
        window.hasShadow = true
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = transparentWindow
                ? NSColor.clear.cgColor
                : NSColor.windowBackgroundColor.cgColor
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
#endif
