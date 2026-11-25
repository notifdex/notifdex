#if os(macOS)
import AppKit
import NotifdexCore
import SwiftUI

/// Native AppKit window controller for App Center (Safari/Mail architecture).
///
/// Key cross-monitor drag stability invariants (matching `spec/WindowChrome.tla`
/// and `spec/WindowDrag.tla`):
/// 1. App Center is owned by a native AppKit `NSWindowController` + `NSWindow`
///    (never a SwiftUI `Window` scene / `_TtC7SwiftUI12AppKitWindow`).
/// 2. `NSApp.setActivationPolicy(.regular)` is set before creating/ordering the
///    window on screen, and restored to `.accessory` in `windowWillClose`.
/// 3. Structural chrome (`styleMask`, `.unifiedCompact`, `NSToolbar`, titlebar
///    appearance) is configured once at window initialization.
/// 4. `AppCenterRootView` isolates the edge-to-edge backdrop in a non-interactive
///    container and pins `NSHostingView` strictly to `window.contentLayoutGuide`
///    with `sizingOptions = []`, so SwiftUI ticks never push frame mutations to `NSWindow`.
/// 5. Titlebar drags are tracked directly in global screen coordinates via
///    `TitlebarDragSession` + `NSWindow.trackEvents(matching:mode:)` + `setFrameOrigin(_:)`,
///    anchored to `(startOrigin, startMouse)` so macOS 27.2's broken SkyLight client-initiated
///    drag trait gesture is bypassed completely (zero snapping, zero cumulative drift).
/// 6. Transparency updates and offscreen-titlebar recovery are deferred by
///    `WindowChromeSyncState` while a drag is active and flushed only when idle.
@MainActor
final class AppCenterWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let appearance: AppearanceSettings
    private let toolbarDelegate = AppCenterToolbarDelegate()
    private var chromeSync = WindowChromeSyncState()
    private var screenObserver: NSObjectProtocol?

    private static let defaultContentSize = NSSize(width: 780, height: 620)
    private static let minimumContentSize = NSSize(width: 660, height: 520)

    init(model: AppModel, appearance: AppearanceSettings) {
        self.model = model
        self.appearance = appearance

        let window = AppCenterWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.delegate = self
        configureWindowOnce(window)
        installContentHierarchy(in: window)
        configureInteractionHooks(on: window)
        installScreenParametersObserver()

        let initialTransparent = appearance.activeConfiguration.requestsTransparentWindow
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let plan = chromeSync.attach(
            windowID: ObjectIdentifier(window),
            transparentWindow: initialTransparent
        )
        apply(plan, to: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func showAppCenter() {
        guard let window else { return }
        // Become a regular app before ordering the window on screen so WindowServer
        // registers it identically to standard desktop apps like Safari.
        NSApp.setActivationPolicy(.regular)
        recoverOffscreenTitlebarIfNeeded(in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func syncTransparencyIfNeeded(_ transparentWindow: Bool) {
        guard let window else { return }
        let plan = chromeSync.requestSync(transparentWindow: transparentWindow)
        apply(plan, to: window)
    }

    private func configureWindowOnce(_ window: AppCenterWindow) {
        window.title = "Notifdex · App Center"
        window.toolbarStyle = .unifiedCompact
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Titlebar dragging is owned deterministically by `TitlebarDragSession` in
        // `AppCenterWindow.sendEvent(_:)` so macOS 27.2's broken SkyLight drag gesture
        // never competes with or snaps our transparent glass window across monitors.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumContentSize

        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("NotifdexAppCenterToolbar"))
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        if !window.setFrameUsingName("NotifdexAppCenterWindow") {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        window.setFrameAutosaveName("NotifdexAppCenterWindow")
    }

    private func installContentHierarchy(in window: AppCenterWindow) {
        let rootView = AppCenterRootView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))

        let backdropContainer = NonInteractiveBackdropContainer()
        backdropContainer.translatesAutoresizingMaskIntoConstraints = false

        let backdropHost = NSHostingView(
            rootView: AppCenterWindowBackdropView(appearance: appearance) { [weak self] transparent in
                self?.syncTransparencyIfNeeded(transparent)
            }
        )
        backdropHost.sizingOptions = []
        backdropHost.translatesAutoresizingMaskIntoConstraints = false
        backdropContainer.addSubview(backdropHost)

        let contentHost = NSHostingView(
            rootView: AppCenter(model: model, appearance: appearance)
        )
        contentHost.sizingOptions = []
        contentHost.translatesAutoresizingMaskIntoConstraints = false

        rootView.addSubview(backdropContainer)
        rootView.addSubview(contentHost)
        window.contentView = rootView

        NSLayoutConstraint.activate([
            backdropContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            backdropContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            backdropContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            backdropContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            backdropHost.leadingAnchor.constraint(equalTo: backdropContainer.leadingAnchor),
            backdropHost.trailingAnchor.constraint(equalTo: backdropContainer.trailingAnchor),
            backdropHost.topAnchor.constraint(equalTo: backdropContainer.topAnchor),
            backdropHost.bottomAnchor.constraint(equalTo: backdropContainer.bottomAnchor),
        ])

        if let contentGuide = window.contentLayoutGuide as? NSLayoutGuide {
            NSLayoutConstraint.activate([
                contentHost.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: contentGuide.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                contentHost.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                contentHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                contentHost.topAnchor.constraint(equalTo: rootView.topAnchor),
                contentHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])
        }
    }

    private func configureInteractionHooks(on window: AppCenterWindow) {
        window.onTitlebarMouseDown = { [weak self, weak window] event in
            guard let self, let window else { return false }
            return self.handleTitlebarMouseDown(event, in: window)
        }
    }

    private func handleTitlebarMouseDown(_ event: NSEvent, in window: NSWindow) -> Bool {
        let hitView = window.contentView?.superview?.hitTest(event.locationInWindow)
        let hitInteractive = Self.isInteractiveControl(hitView)
        let isDraggable = TitlebarDragZone.isInDraggableTitlebar(
            point: WindowPoint(
                x: Double(event.locationInWindow.x),
                y: Double(event.locationInWindow.y)
            ),
            windowSize: WindowPoint(
                x: Double(window.frame.size.width),
                y: Double(window.frame.size.height)
            ),
            contentMaxY: Double(window.contentLayoutRect.maxY),
            hitInteractiveControl: hitInteractive,
            isFullScreen: window.styleMask.contains(.fullScreen)
        )
        guard isDraggable else { return false }

        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        chromeSync.mouseDown()
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let titlebarHeight = max(
            AppTitlebarStyle.unifiedCompact.nominalHeight,
            Double(window.frame.height - window.contentLayoutRect.maxY)
        )
        var session = TitlebarDragSession(
            startMouse: WindowPoint(x: Double(startMouse.x), y: Double(startMouse.y)),
            startOrigin: WindowPoint(x: Double(startOrigin.x), y: Double(startOrigin.y)),
            windowSize: WindowPoint(x: Double(window.frame.width), y: Double(window.frame.height)),
            titlebarHeight: titlebarHeight
        )
        var startedDrag = false
        var releaseEvent: NSEvent?

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { [weak self, weak window] trackedEvent, stop in
            guard let self, let window, let trackedEvent else {
                stop.pointee = true
                return
            }
            switch trackedEvent.type {
            case .leftMouseDragged:
                let currentMouse = NSEvent.mouseLocation
                if let nextOrigin = session.updatedOrigin(
                    for: WindowPoint(x: Double(currentMouse.x), y: Double(currentMouse.y)),
                    visibleScreens: self.visibleScreenRects()
                ) {
                    if !startedDrag {
                        startedDrag = true
                        self.chromeSync.beginDrag()
                    }
                    window.setFrameOrigin(NSPoint(x: nextOrigin.x, y: nextOrigin.y))
                }
            case .leftMouseUp:
                releaseEvent = trackedEvent
                stop.pointee = true
            default:
                break
            }
        }

        if startedDrag {
            finishDragIfNeeded(in: window)
        } else if let upEvent = releaseEvent, event.clickCount == 2 || upEvent.clickCount == 2 {
            _ = handleTitlebarDoubleClickIfNeeded(
                upEvent,
                clickCount: max(event.clickCount, upEvent.clickCount),
                in: window,
                didDrag: false
            )
        }
        return true
    }

    private func installScreenParametersObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                if self.chromeSync.noteDisplayReconfiguration() {
                    self.recoverOffscreenTitlebarIfNeeded(in: window)
                }
            }
        }
    }

    private func apply(_ plan: WindowChromeMutationPlan, to window: NSWindow) {
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

        if plan.shouldCheckBoundsRecovery {
            recoverOffscreenTitlebarIfNeeded(in: window)
        }
    }

    private func finishDragIfNeeded(in window: NSWindow) {
        let plan = chromeSync.endDrag()
        apply(plan, to: window)
    }

    private func visibleScreenRects() -> [WindowRect] {
        NSScreen.screens.map { screen in
            let rect = screen.visibleFrame
            return WindowRect(
                x: Double(rect.origin.x),
                y: Double(rect.origin.y),
                width: Double(rect.size.width),
                height: Double(rect.size.height)
            )
        }
    }

    private func recoverOffscreenTitlebarIfNeeded(in window: NSWindow) {
        let screens = visibleScreenRects()
        let current = WindowRect(
            x: Double(window.frame.origin.x),
            y: Double(window.frame.origin.y),
            width: Double(window.frame.size.width),
            height: Double(window.frame.size.height)
        )
        let titlebarHeight = max(
            AppTitlebarStyle.unifiedCompact.nominalHeight,
            Double(window.frame.height - window.contentLayoutRect.maxY)
        )
        guard let recovered = WindowPlacementGeometry.recoveredFrame(
            for: current,
            visibleScreens: screens,
            isDragging: chromeSync.isDragging,
            titlebarHeight: titlebarHeight
        ) else {
            return
        }
        let targetRect = NSRect(
            x: recovered.x,
            y: recovered.y,
            width: recovered.width,
            height: recovered.height
        )
        window.setFrame(targetRect, display: true, animate: false)
    }

    private func handleTitlebarDoubleClickIfNeeded(
        _ event: NSEvent,
        clickCount: Int,
        in window: NSWindow,
        didDrag: Bool
    ) -> Bool {
        let hitView = window.contentView?.superview?.hitTest(event.locationInWindow)
        let hitInteractive = Self.isInteractiveControl(hitView)
        let setting = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
        let action = TitlebarDoubleClickAction.actionForClick(
            clickCount: clickCount,
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
            return true
        case .minimize:
            window.miniaturize(nil)
            return true
        case .none:
            return false
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

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard let window else { return }
        if chromeSync.isDragging {
            finishDragIfNeeded(in: window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window, chromeSync.isDragging {
            finishDragIfNeeded(in: window)
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
private final class AppCenterWindow: NSWindow {
    var onTitlebarMouseDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           !event.modifierFlags.contains(.control),
           onTitlebarMouseDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// Root content view that lets all titlebar-band hits (`y >= contentLayoutRect.maxY`)
/// pass straight through to native `NSThemeFrame`.
@MainActor
private final class AppCenterRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, point.y >= window.contentLayoutRect.maxY {
            return nil
        }
        return super.hitTest(point)
    }
}

@MainActor
private final class NonInteractiveBackdropContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private final class BrandTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class AppCenterToolbarDelegate: NSObject, NSToolbarDelegate {
    private static let brandItemIdentifier = NSToolbarItem.Identifier("com.notifdex.toolbar.brand")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.brandItemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.brandItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.brandItemIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        item.isNavigational = true
        item.label = "Notifdex"

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let icon = AppIconCatalog.appIconImage {
            let imageView = NSImageView(image: icon)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 5
            imageView.layer?.masksToBounds = true
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(equalToConstant: 20),
            ])
            stack.addArrangedSubview(imageView)
        }

        let titleField = NSTextField(labelWithString: "Notifdex")
        let baseDescriptor = NSFont.systemFont(ofSize: 15, weight: .regular).fontDescriptor
        if let serifDescriptor = baseDescriptor.withDesign(.serif),
           let serifFont = NSFont(descriptor: serifDescriptor, size: 15) {
            titleField.font = serifFont
        } else {
            titleField.font = NSFont.systemFont(ofSize: 15, weight: .regular)
        }
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(titleField)

        let container = BrandTitlebarView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        item.view = container
        return item
    }
}
#endif
