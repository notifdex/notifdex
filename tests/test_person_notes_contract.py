import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class PersonNotesContractTests(unittest.TestCase):
    def test_notes_schema_preserves_people_and_requires_an_owner(self):
        with sqlite3.connect(":memory:") as db:
            db.execute("PRAGMA foreign_keys = ON")
            for name in ("schema", "inbox-work", "filters", "person-matches"):
                db.executescript((SCHEMAS / f"{name}.sql").read_text())
            db.execute("INSERT INTO people VALUES ('a', 'Alex'), ('b', 'Alex')")
            db.executescript((SCHEMAS / "person-notes.sql").read_text())

            db.execute("INSERT INTO person_notes VALUES ('note-1', 'a', 'Met on Tuesday', 3, 3)")
            self.assertEqual(db.execute("SELECT COUNT(*) FROM people").fetchone(), (2,))
            self.assertEqual(
                db.execute("SELECT body FROM person_notes WHERE person_id = 'a'").fetchall(),
                [("Met on Tuesday",)],
            )
            self.assertEqual(db.execute("SELECT body FROM person_notes WHERE person_id = 'b'").fetchall(), [])
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO person_notes VALUES ('orphan', 'missing', 'Text', 3, 3)")
