import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class NotebookContractTests(unittest.TestCase):
    def test_upgrade_preserves_person_notes_and_folder_deletion_unfiles(self):
        with sqlite3.connect(":memory:") as db:
            db.execute("PRAGMA foreign_keys = ON")
            for name in ("schema", "inbox-work", "person-notes"):
                db.executescript((SCHEMAS / f"{name}.sql").read_text())
            db.execute("INSERT INTO people VALUES ('p', 'Maya')")
            db.execute("INSERT INTO person_notes VALUES ('old', 'p', 'Legacy text', 1, 2)")
            db.executescript((SCHEMAS / "notebook.sql").read_text())
            self.assertEqual(db.execute("SELECT id, person_id, title, body, created_at, updated_at FROM person_notes").fetchone(),
                             ('old', 'p', '', 'Legacy text', 1, 2))
            db.execute("INSERT INTO note_folders VALUES ('f', 'Ideas')")
            db.execute("INSERT INTO personal_notes VALUES ('n', 'f', 'Title', 'Text', 3, 3)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE personal_notes SET folder_id = 'missing' WHERE id = 'n'")
            db.execute("DELETE FROM note_folders WHERE id = 'f'")
            self.assertEqual(db.execute("SELECT folder_id, title, body FROM personal_notes").fetchone(),
                             (None, 'Title', 'Text'))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM person_notes").fetchone(), (1,))
