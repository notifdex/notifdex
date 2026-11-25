import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexApp"


class AppCenterLayoutContractTests(unittest.TestCase):
    def test_sidebar_and_compact_picker_share_the_workflow_mode(self):
        source = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("ForEach(WorkflowMode.allCases)", source)
        self.assertIn("model.mode = mode", source)
        self.assertIn('Picker("View", selection: $model.mode)', source)
        self.assertIn('Menu("Sort & group")', source)

    def test_apps_and_recovery_are_folded_into_the_unified_sidebar(self):
        app_source = (APP_DIR / "NotifdexApp.swift").read_text()
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertNotIn("TabView {", app_source)
        self.assertIn('case apps = "Apps"', workflow)
        self.assertIn('case recovery = "Recovery"', workflow)
        self.assertIn("else if model.mode == .apps", workflow)
        self.assertIn("else if model.mode == .recovery", workflow)

    def test_inspector_uses_model_selection_and_keeps_people_overview(self):
        source = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("model.mode == .people || model.selected != nil", source)
        self.assertIn("if showsInspector", source)
        self.assertIn('Label("Back to alerts", systemImage: "chevron.left")', source)
        self.assertIn('Label("Back to person", systemImage: "chevron.left")', source)
        self.assertIn("keepsOpenDetail, let selected", source)

    def test_app_center_uses_native_window_sizing(self):
        source = (APP_DIR / "NotifdexApp.swift").read_text()
        presence = (APP_DIR / "AppCenterPresence.swift").read_text()
        self.assertNotIn('Menu("Window Size")', source)
        self.assertNotIn(".windowStyle(.hiddenTitleBar)", source)
        self.assertIn(".defaultSize(width: 780, height: 620)", source)
        self.assertIn("window.titlebarAppearsTransparent = true", presence)

    def test_inbox_detail_defaults_to_the_available_maximum_and_can_resize(self):
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("min(640, geometry.size.width - minimumFeedWidth - dividerWidth)", workflow)
        self.assertIn("inboxDetailWidth ?? maximumWidth", workflow)
        self.assertIn("inboxDetailWidth = clamped(startWidth - value.translation.width)", workflow)
        self.assertIn("if !visible { model.inboxDetailWidth = nil }", workflow)
        self.assertIn("ResizeCursorArea", workflow)
        self.assertIn("resetCursorRects", workflow)
        self.assertIn(".highPriorityGesture(", workflow)

    def test_appearance_studio_exposes_see_through_glass_tiers_and_custom_background(self):
        appearance = (APP_DIR / "AppAppearance.swift").read_text()
        core = (Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore" / "AppearancePreferences.swift").read_text()
        studio = (APP_DIR / "AppearanceStudioView.swift").read_text()
        app_source = (APP_DIR / "NotifdexApp.swift").read_text()
        self.assertIn("surfaceMode: AppSurfaceMode = .clearGlass", core)
        self.assertIn("NSVisualEffectView", appearance)
        self.assertIn("blendingMode: .behindWindow", appearance)
        self.assertIn("enum AppThemeTier", core)
        self.assertIn("ForEach(AppSurfaceMode.allCases)", studio)
        self.assertIn("ForEach(AppColorTheme.coreThemes)", studio)
        self.assertIn("ForEach(AppColorTheme.studioThemes)", studio)
        self.assertIn('Label("Show data folder"', studio)
        self.assertIn("appearance.importBackdrop(result)", app_source)
        self.assertIn("appearance.removeCustomBackdrop()", studio)

    def test_solid_surface_preserves_mode_and_applies_pigment_on_theme_change(self):
        appearance = (APP_DIR / "AppAppearance.swift").read_text()
        core_path = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore" / "AppearancePreferences.swift"
        self.assertTrue(core_path.is_file(), "Expected platform-independent AppearancePreferences state model in NotifdexCore")
        core = core_path.read_text()
        # Bug #70 regression: selecting a color pigment in Solid (.standard) must never snap back to .clearGlass.
        self.assertNotIn("if surfaceMode == .standard {\n            surfaceMode = .clearGlass", appearance)
        self.assertNotIn("if surfaceMode == .standard {\n            surfaceMode = .clearGlass", core)
        self.assertIn("func selectTheme(", core)
        self.assertIn("func standardWindowFill(", appearance)
        self.assertIn("func standardPlane(", appearance)
        self.assertIn("tokens: ThemeTokens", appearance)

    def test_global_controls_and_banners_remain_reachable(self):
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        studio = (APP_DIR / "AppearanceStudioView.swift").read_text()
        self.assertIn('Label("Show data folder"', studio)
        self.assertIn(".popover(isPresented: $appModel.showingCollectionStatus", workflow)
        self.assertIn(".popover(isPresented: $appearance.showingStudio", workflow)
        self.assertIn('Toggle("Paused", isOn: appModel.pauseBinding)', workflow)
        self.assertIn('Button("Retry starting capture")', workflow)
        self.assertIn('Button("Open Accessibility Settings")', workflow)

    def test_bundled_app_icon_and_sidebar_brand_mark_are_wired(self):
        icons_dir = Path(__file__).resolve().parents[1] / "Resources" / "Icons"
        self.assertTrue((icons_dir / "AppIcon.png").is_file(), "Missing bundled AppIcon.png")
        studio = (APP_DIR / "AppearanceStudioView.swift").read_text()
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        presence = (APP_DIR / "AppCenterPresence.swift").read_text()
        chrome_core = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore" / "WindowChromeLayout.swift"
        self.assertTrue(chrome_core.is_file(), "Expected platform-independent WindowChromeLayout specification in NotifdexCore")
        self.assertIn("ForEach(MenuBarIconStyle.allCases)", studio)
        self.assertIn("AppIconCatalog.appIconImage", workflow)
        # Single titlebar owner: native SwiftUI .toolbar + .unifiedCompact (~38pt), NEVER manual empty NSToolbar + .ignoresSafeArea.
        self.assertIn(".toolbar {", workflow)
        self.assertIn("ToolbarItem(placement: .navigation)", workflow)
        self.assertIn(".sharedBackgroundVisibility(.hidden)", workflow)
        self.assertIn("window.toolbarStyle = .unifiedCompact", presence)
        self.assertNotIn("window.toolbar = toolbar", presence)
        self.assertNotIn(".ignoresSafeArea(.container, edges: .top)", workflow)
        # Cross-monitor drag stability: AppCenterPresence must use WindowChromeSyncState so SwiftUI updates never mutate NSWindow chrome mid-drag.
        self.assertIn("WindowChromeSyncState", presence)
        self.assertIn("NSWindow.willMoveNotification", presence)
        self.assertIn("didDrag:", presence)
        # Status & Appearance controls stay anchored in the LHS sidebar footer (with compact-header fallback).
        self.assertIn("sidebarFooter", workflow)
        self.assertNotIn("ToolbarItemGroup(placement: .primaryAction)", workflow)
        # Native macOS titlebar double-click (Zoom / Minimize per AppleActionOnDoubleClick) must remain active.
        self.assertIn("addLocalMonitorForEvents(matching: .leftMouseUp)", presence)
        self.assertIn("TitlebarDoubleClickAction", presence)
        self.assertIn("performZoom", presence)
        self.assertIn("miniaturize", presence)
        # LHS sidebar uses legible >=14pt typography and main panel does not repeat the active mode title.
        self.assertIn("WindowChromeState.sidebarLabelFontSize", workflow)
        self.assertNotIn("Text(model.mode.rawValue)", workflow)

    def test_open_in_messages_uses_bundle_id_and_can_open_guard(self):
        inbox_core = (Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore" / "Inbox.swift").read_text()
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn('case "Messages": "com.apple.MobileSMS"', inbox_core)
        self.assertIn("static func canOpen(", inbox_core)
        self.assertIn("if InboxDestination.canOpen(alert.app)", workflow)
        self.assertIn("InboxDestination.bundleIdentifier(for: alert.app)", workflow)
