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

    def test_window_sizing_actions_are_reachable_from_app_center(self):
        source = (APP_DIR / "NotifdexApp.swift").read_text()
        self.assertIn('Menu("Window Size")', source)
        for label in ("Standard", "Wide", "Toggle Full Screen"):
            self.assertIn(f'Button("{label}")', source)
        self.assertIn("screen.visibleFrame", source)

    def test_default_window_opens_with_room_for_a_wider_inspector(self):
        app = (APP_DIR / "NotifdexApp.swift").read_text()
        workflow = (APP_DIR / "WorkflowView.swift").read_text()
        self.assertIn("appCenterDefaultSize = CGSize(width: 1060, height: 660)", app)
        self.assertIn(".defaultSize(width: appCenterDefaultSize.width", app)
        self.assertIn("minimumFeedWidth: CGFloat = 250", workflow)
        self.assertIn("maximumInspectorWidth: CGFloat = 640", workflow)
        self.assertIn("idealWidth: showsInspector ? minimumFeedWidth : 425", workflow)
        self.assertIn(".frame(minWidth: 300, idealWidth: maximumInspectorWidth, maxWidth: maximumInspectorWidth)", workflow)

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
