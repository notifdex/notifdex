import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "Sources" / "NotifdexApp" / "WorkflowView.swift"
POPOVERS = ROOT / "Sources" / "NotifdexApp" / "ContactPopoverViews.swift"
SUGGESTIONS = ROOT / "Sources" / "NotifdexCore" / "ContactSuggestions.swift"


class ContactUXContractTests(unittest.TestCase):
    def test_alert_detail_uses_contextual_contact_banners_and_popovers(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        popovers = POPOVERS.read_text(encoding="utf-8")
        self.assertIn("alertContactBanners(alert, tokens: tokens)", workflow)
        self.assertIn("linkedContactPill(personID: personID", workflow)
        self.assertIn('Text("Possible match:', workflow)
        self.assertIn('Button("New Person…")', workflow)
        self.assertIn('Button("Add to Existing…")', workflow)
        self.assertIn("NewPersonPopoverView(", workflow)
        self.assertIn("SearchablePersonPopoverView(", workflow)
        self.assertIn("ContactCardPopoverView(", workflow)
        self.assertIn("Create “\\(trimmedQuery)” and link", popovers)

    def test_people_bar_has_searchable_switcher_and_persistent_new_person_button(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("model.openPeopleSwitcherPopover()", workflow)
        self.assertIn('Label("New Person", systemImage: "person.badge.plus")', workflow)
        self.assertIn("model.openNewPersonPopover(for: nil, inPeopleBar: true)", workflow)
        self.assertIn("Button(\"Rename…\")", workflow)
        self.assertIn("Button(\"Delete person…\", role: .destructive)", workflow)

    def test_contact_suggestions_is_read_only_in_core(self):
        source = SUGGESTIONS.read_text(encoding="utf-8")
        self.assertIn("enum ContactSuggestions", source)
        self.assertIn("case ambiguous([PersonRecord])", source)
        self.assertIn("static func availablePlatforms(", source)
        self.assertNotIn("CaptureStore", source)

    def test_handle_platform_pickers_include_custom_configured_apps(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("ContactSuggestions.availablePlatforms(", workflow)
        self.assertIn("configuredApps: appModel.state.settings?.apps ?? []", workflow)
        self.assertIn("observedApps: apps", workflow)
        self.assertNotIn("ForEach(ContactSuggestions.supportedPlatforms", workflow)
