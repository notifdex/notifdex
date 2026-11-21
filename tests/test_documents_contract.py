import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class DocumentsContractTests(unittest.TestCase):
    def test_docs_are_independent_of_prior_data(self):
        with sqlite3.connect(":memory:") as db:
            db.execute("PRAGMA foreign_keys = ON")
            for name in ("schema", "inbox-work", "person-notes", "notebook"):
                db.executescript((SCHEMAS / f"{name}.sql").read_text())
            db.execute("INSERT INTO people VALUES ('p', 'Reader')")
            db.execute("INSERT INTO person_notes VALUES ('person-note', 'p', 'Context', 1, 1, '')")
            db.execute("INSERT INTO personal_notes VALUES ('my-note', NULL, 'Note', 'Other context', 1, 1)")
            db.executescript((SCHEMAS / "documents.sql").read_text())
            db.execute("INSERT INTO documents VALUES ('doc', 'Reference', '# Heading', 2, 2)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE documents SET updated_at = 1 WHERE id = 'doc'")
            self.assertEqual(db.execute("SELECT body, updated_at FROM documents").fetchone(), ('# Heading', 2))
            db.execute("DELETE FROM documents WHERE id = 'doc'")
            self.assertEqual(db.execute("SELECT body FROM personal_notes").fetchone(), ('Other context',))
            self.assertEqual(db.execute("SELECT body FROM person_notes").fetchone(), ('Context',))
