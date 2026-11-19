import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class PeopleWorkspaceContractTests(unittest.TestCase):
    def test_many_to_many_memberships_and_separate_routing(self):
        with sqlite3.connect(":memory:") as db:
            db.executescript("""
                PRAGMA foreign_keys = ON;
                CREATE TABLE people(id TEXT PRIMARY KEY);
                CREATE TABLE observations(id INTEGER PRIMARY KEY);
                INSERT INTO people VALUES ('alex'), ('sam');
                INSERT INTO observations VALUES (1), (2);
            """)
            db.executescript((SCHEMAS / "workspaces.sql").read_text())
            db.execute("INSERT INTO workspaces VALUES ('personal', 'Personal'), ('startup', 'Startup 1')")
            db.execute("INSERT INTO person_workspaces VALUES ('alex', 'personal'), ('alex', 'startup')")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO person_workspaces VALUES ('alex', 'personal')")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO person_workspaces VALUES ('sam', 'unknown')")
            self.assertEqual(db.execute("SELECT * FROM observation_workspaces").fetchall(), [])
            db.execute("INSERT INTO observation_workspaces VALUES (1, 'personal'), (2, 'startup')")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO observation_workspaces VALUES (1, 'startup')")
            db.execute("DELETE FROM person_workspaces WHERE person_id = 'alex' AND workspace_id = 'personal'")
            self.assertEqual(db.execute("SELECT * FROM person_workspaces").fetchall(), [('alex', 'startup')])
            self.assertEqual(db.execute("SELECT * FROM people").fetchall(), [('alex',), ('sam',)])
            self.assertEqual(db.execute("SELECT * FROM observation_workspaces").fetchall(),
                             [(1, 'personal'), (2, 'startup')])
