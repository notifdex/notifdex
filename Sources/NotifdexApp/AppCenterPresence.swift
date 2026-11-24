#if os(macOS)
import AppKit
import NotifdexCore
import SwiftUI

/// Keep the collector in the menu bar while its main window is closed, configure
/// compact unified window chrome, and preserve native titlebar double-click behavior
/// when `titleVisibility = .hidden` is used with a SwiftUI toolbar.
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
    private var doubleClickMonitor: Any?

    deinit {
        if let monitor = doubleClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        removeDoubleClickMonitor()
        guard let window else { return }
        Self.appCenterWindow = window
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
        applyWindowChrome()
        installDoubleClickMonitor(for: window)
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

    private func installDoubleClickMonitor(for targetWindow: NSWindow) {
        removeDoubleClickMonitor()
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak targetWindow] event in
            guard let window = targetWindow, event.window === window else {
                return event
            }
            let hitView = window.contentView?.superview?.hitTest(event.locationInWindow)
            let hitInteractive = Self.isInteractiveControl(hitView)
            let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            let action = TitlebarDoubleClickAction.actionForClick(
                clickCount: event.clickCount,
                locationY: Double(event.locationInWindow.y),
                windowHeight: Double(window.frame.height),
                contentMaxY: Double(window.contentLayoutRect.maxY),
                hitInteractiveControl: hitInteractive,
                systemSetting: setting
            )
            switch action {
            case .zoom:
                window.performZoom(nil)
                return nil
            case .minimize:
                window.miniaturize(nil)
                return nil
            case .none:
                return event
            }
        }
    }

    private func removeDoubleClickMonitor() {
        if let monitor = doubleClickMonitor {
            NSEvent.removeMonitor(monitor)
            doubleClickMonitor = nil
        }
    }

    private static func isInteractiveControl(_ view: NSView?) -> Bool {
        var cursor = view
        while let current = cursor {
            if current is NSControl {
                return true
            }
            cursor = current.superview
        }
        return false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        removeDoubleClickMonitor()
        NSApp.setActivationPolicy(.accessory)
    }
}
#endif
