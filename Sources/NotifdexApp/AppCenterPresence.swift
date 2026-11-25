#if os(macOS)
import AppKit
import NotifdexCore
import SwiftUI

/// Keep the collector in the menu bar while its main window is closed, configure
/// compact unified window chrome without mutating NSWindow properties mid-drag,
/// and preserve native titlebar double-click behavior when `titleVisibility = .hidden`
/// is used with a SwiftUI toolbar.
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
        view.syncWindowChromeIfNeeded()
    }
}

@MainActor
final class AppCenterPresenceView: NSView {
    static weak var appCenterWindow: NSWindow?
    var transparentWindow: Bool = true

    private var chromeSync = WindowChromeSyncState()
    private var mouseDownInWindow = false
    private var dragTrackMonitor: Any?
    private var doubleClickMonitor: Any?

    deinit {
        if let monitor = dragTrackMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = doubleClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        removeEventMonitors()
        mouseDownInWindow = false
        guard let window else {
            chromeSync.detach()
            return
        }
        Self.appCenterWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillMove(_:)),
            name: NSWindow.willMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        let plan = chromeSync.attach(
            windowID: ObjectIdentifier(window),
            transparentWindow: transparentWindow
        )
        apply(plan, to: window)
        installEventMonitors(for: window)
        NSApp.setActivationPolicy(.regular)
    }

    func syncWindowChromeIfNeeded() {
        guard let window else { return }
        let plan = chromeSync.requestSync(transparentWindow: transparentWindow)
        apply(plan, to: window)
    }

    private func apply(_ plan: WindowChromeMutationPlan, to window: NSWindow) {
        guard plan.mutatesWindow else { return }

        if plan.applyStructuralChrome {
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.toolbarStyle != .unifiedCompact {
                window.toolbarStyle = .unifiedCompact
            }
            if let toolbar = window.toolbar, toolbar.showsBaselineSeparator {
                toolbar.showsBaselineSeparator = false
            }
            if !window.titlebarAppearsTransparent {
                window.titlebarAppearsTransparent = true
            }
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
            }
            if window.isMovableByWindowBackground {
                window.isMovableByWindowBackground = false
            }
            if !window.hasShadow {
                window.hasShadow = true
            }
        }

        if plan.applyTransparency {
            let desiredOpaque = !plan.transparentWindow
            if window.isOpaque != desiredOpaque {
                window.isOpaque = desiredOpaque
            }
            let desiredBackground: NSColor = plan.transparentWindow ? .clear : .windowBackgroundColor
            if window.backgroundColor != desiredBackground {
                window.backgroundColor = desiredBackground
            }
            if let contentView = window.contentView {
                if !contentView.wantsLayer {
                    contentView.wantsLayer = true
                }
                contentView.layer?.backgroundColor = desiredBackground.cgColor
            }
        }
    }

    private func installEventMonitors(for targetWindow: NSWindow) {
        removeEventMonitors()

        dragTrackMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self, weak targetWindow] event in
            guard let self, let window = targetWindow, event.window === window else {
                return event
            }
            switch event.type {
            case .leftMouseDown:
                self.mouseDownInWindow = true
                self.chromeSync.mouseDown()
            case .leftMouseDragged:
                if self.mouseDownInWindow {
                    self.chromeSync.beginDrag()
                }
            default:
                break
            }
            return event
        }

        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self, weak targetWindow] event in
            guard let self, let window = targetWindow else {
                return event
            }
            let wasDragging = self.chromeSync.isDragging
            let didDrag = self.chromeSync.draggedSinceMouseDown
            self.mouseDownInWindow = false
            let deferredPlan = self.chromeSync.endDrag()
            self.apply(deferredPlan, to: window)

            guard event.window === window, !wasDragging else {
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
                didDrag: didDrag,
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

    private func removeWindowObservers() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willMoveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    private func removeEventMonitors() {
        if let monitor = dragTrackMonitor {
            NSEvent.removeMonitor(monitor)
            dragTrackMonitor = nil
        }
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

    @objc private func windowWillMove(_ notification: Notification) {
        if mouseDownInWindow || (NSEvent.pressedMouseButtons & 1) != 0 {
            chromeSync.beginDrag()
        }
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window else { return }
        mouseDownInWindow = false
        let deferredPlan = chromeSync.endDrag()
        apply(deferredPlan, to: window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        removeWindowObservers()
        removeEventMonitors()
        mouseDownInWindow = false
        chromeSync.detach()
        NSApp.setActivationPolicy(.accessory)
    }
}
#endif
