import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexApp" / "WorkflowView.swift"


class PeopleNavigationContractTests(unittest.TestCase):
    def test_overview_button_clears_only_the_selected_alert(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertRegex(
            source,
            r'Button\s*\{\s*model\.selected = nil\s*\}\s*label:\s*\{'
            r'\s*Label\("Back to person", systemImage: "chevron.left"\)',
        )

    def test_people_overview_uses_the_left_list_for_activity(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("personCard(id: card.id, name: card.name, showRecentActivity: false)", source)
        self.assertTrue(re.search(r'if showRecentActivity\s*\{\s*Text\("Recent activity"\)', source))

    def test_person_card_has_workspace_menu_and_template_removal_confirmation(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('LabeledContent("Workspaces")', source)
        self.assertIn("Menu(summary)", source)
        self.assertIn("model.personWorkspaceIDs.contains(workspace.id)", source)
        self.assertIn('Button("Remove template…")', source)
        self.assertIn('Button("Remove template", role: .destructive)', source)
