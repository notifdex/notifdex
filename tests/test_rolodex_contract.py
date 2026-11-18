"""Check the version-two SQL against an existing capture database."""
import sqlite3
import unittest

from test_storage_contract import INSERT, SCHEMA


class RolodexContract(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.executescript(SCHEMA.read_text())
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("INSERT INTO capture_runs VALUES ('run', 1, 1, NULL)")
        self.db.execute(INSERT, ("a", "Hello", "X, Alex, Hello, from iPhone"))
        self.db.commit()
        self.db.executescript(SCHEMA.with_name("rolodex.sql").read_text())

    def test_upgrade_keeps_observations_and_clears_no_evidence(self):
        self.assertEqual(self.db.execute("SELECT body FROM observations").fetchone(), ("Hello",))
        self.assertEqual(self.db.execute("SELECT count(*) FROM observation_work").fetchone(), (0,))

    def test_done_requires_due_date_and_work_requires_observation(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO observation_work VALUES (1, 1, NULL, 1)")
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO observation_work VALUES (2, 1, 12, 0)")
        self.db.execute("INSERT INTO observation_work VALUES (1, 1, 12, 1)")
        self.assertEqual(self.db.execute("SELECT saved, due_at, done FROM observation_work").fetchone(), (1, 12, 1))
