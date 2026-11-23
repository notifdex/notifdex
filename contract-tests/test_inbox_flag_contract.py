import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class InboxFlagContractTests(unittest.TestCase):
    def test_v6_flags_reference_existing_observations_and_preserve_read_state(self):
        with sqlite3.connect(":memory:") as db:
            db.execute("PRAGMA foreign_keys = ON")
            for name in ("schema", "inbox-work", "filters", "person-matches", "person-notes"):
                db.executescript((SCHEMAS / f"{name}.sql").read_text())
            db.execute("INSERT INTO capture_runs VALUES ('old', 1, 2, 2)")
            db.execute("""
                INSERT INTO observations VALUES
                    (42, 'phone', 'banner', 'old', 2, 'iphone', 'Gmail',
                     'Alex', '', 'Hello', 'Gmail, Alex, Hello, from iPhone', 1)
                """)
            db.execute("INSERT INTO read_observations VALUES (42)")
            db.executescript((SCHEMAS / "flags.sql").read_text())
            self.assertEqual(db.execute("SELECT * FROM flagged_observations").fetchall(), [])
            db.execute("INSERT INTO flagged_observations VALUES (42)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO flagged_observations VALUES (99)")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO flagged_observations VALUES (42)")
            db.execute("DELETE FROM flagged_observations WHERE observation_id = 42")
            self.assertEqual(db.execute("SELECT * FROM read_observations").fetchall(), [(42,)])
