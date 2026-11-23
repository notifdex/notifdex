import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class RelationshipTemplateContractTests(unittest.TestCase):
    def test_version_pin_and_assignment_atomicity(self):
        with sqlite3.connect(":memory:") as db:
            db.executescript("PRAGMA foreign_keys=ON; CREATE TABLE people(id TEXT PRIMARY KEY);")
            db.executescript((SCHEMAS / "relationship-templates.sql").read_text())
            db.execute("INSERT INTO people VALUES ('alex'), ('sam')")
            db.executemany("INSERT INTO relationship_templates VALUES ('outreach', ?, '{}')", [(1,), (2,)])
            db.commit()

            with self.assertRaises(sqlite3.IntegrityError), db:
                db.execute("INSERT INTO person_templates VALUES ('alex', 'outreach', 1, 'contacted')")
                db.execute("INSERT INTO person_template_milestones VALUES ('alex', 'slack', 0)")
                db.execute("INSERT INTO person_template_milestones VALUES ('alex', 'tried', 2)")
            self.assertEqual(db.execute("SELECT * FROM person_templates").fetchall(), [])
            self.assertEqual(db.execute("SELECT * FROM person_template_milestones").fetchall(), [])

            db.execute("INSERT INTO person_templates VALUES ('alex', 'outreach', 1, 'contacted')")
            db.execute("INSERT INTO person_template_milestones VALUES ('alex', 'slack', 1)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO person_templates VALUES ('alex', 'outreach', 2, 'contacted')")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO person_templates VALUES ('sam', 'outreach', 3, 'contacted')")
            self.assertEqual(db.execute("SELECT version FROM person_templates").fetchall(), [(1,)])
            self.assertEqual(db.execute("SELECT completed FROM person_template_milestones").fetchall(), [(1,)])
