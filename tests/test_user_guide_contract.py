import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexApp"


class UserGuideContractTests(unittest.TestCase):
    def test_docs_entry_displays_an_offline_guide(self):
        workflow = (APP / "WorkflowView.swift").read_text()
        self.assertRegex(workflow, r"else if model\.mode == \.docs \{\s*UserGuideView\(\)")
        guide = (APP / "UserGuideView.swift").read_text()
        for topic in ("Get started", "How capture works", "Inbox and follow-ups",
                      "People and workspaces", "Notes and saved documents", "Recovery and troubleshooting"):
            self.assertIn(f'"{topic}"', guide)

    def test_existing_document_library_remains_reachable_from_notes(self):
        workflow = (APP / "WorkflowView.swift").read_text()
        self.assertIn('case documents = "Saved Documents"', workflow)
        self.assertRegex(workflow, r"model\.noteCollection == \.documents \{\s*SavedDocumentsView\(worker: worker, ready: ready\)")
