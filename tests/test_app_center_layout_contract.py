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

    def test_inspector_uses_model_selection_and_keeps_people_overview(self):
        source = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("model.mode == .people || model.selected != nil", source)
        self.assertIn("if showsInspector", source)
        self.assertIn('Label("Back to alerts", systemImage: "chevron.left")', source)
        self.assertIn('Label("Back to person", systemImage: "chevron.left")', source)
        self.assertIn("keepsOpenDetail, let selected", source)

    def test_app_center_uses_native_window_sizing(self):
        source = (APP_DIR / "NotifdexApp.swift").read_text()
        self.assertNotIn('Menu("Window Size")', source)
        self.assertIn(".defaultSize(width: 780, height: 620)", source)

    def test_inbox_detail_defaults_to_the_available_maximum_and_can_resize(self):
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("min(640, geometry.size.width - minimumFeedWidth - dividerWidth)", workflow)
        self.assertIn("inboxDetailWidth ?? maximumWidth", workflow)
        self.assertIn("inboxDetailWidth = clamped(startWidth - value.translation.width)", workflow)
        self.assertIn("if !visible { model.inboxDetailWidth = nil }", workflow)

    def test_appearance_options_are_direct_settings_actions(self):
        source = (APP_DIR / "NotifdexApp.swift").read_text()
        self.assertIn('Section("Appearance")', source)
        self.assertIn("Button { appearance = option }", source)
        self.assertNotIn('Picker("Appearance", selection: $appearance)', source)

    def test_top_level_tabs_and_global_controls_remain_reachable(self):
        source = (APP_DIR / "NotifdexApp.swift").read_text()
        for label in ("Inbox", "Apps", "Recovery"):
            self.assertIn(f'.tabItem {{ Label("{label}"', source)
        self.assertIn('Menu("Settings")', source)
        self.assertIn('Button("Show data folder")', source)
        self.assertIn('.popover(isPresented: $model.showingCollectionStatus', source)
        self.assertIn('Toggle("Paused", isOn: model.pauseBinding)', source)
        self.assertIn('Button("Retry starting capture")', source)
        self.assertIn('Button("Open Accessibility Settings")', source)
