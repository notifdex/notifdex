"""A filter survives migration and has no effect on evidence or saved work."""
import sqlite3
import unittest

from test_storage_contract import SCHEMA


class InboxFilterContract(unittest.TestCase):
    def test_migration_preserves_evidence_and_work(self):
        with sqlite3.connect(":memory:") as db:
            self.addCleanup(db.close)
            db.executescript(SCHEMA.read_text())
            db.executescript(SCHEMA.with_name("rolodex.sql").read_text())
            db.execute("INSERT INTO capture_runs VALUES ('run', 1, 1, NULL)")
            db.execute("""INSERT INTO observations VALUES
                (1,'device','alert','run',2,'iphone','Gmail','Example','','Weekly Digest','fixture',1)""")
            db.execute("INSERT INTO observation_work VALUES (1, 1, 9, 0)")
            db.commit()
            db.executescript(SCHEMA.with_name("filters.sql").read_text())
            db.execute("INSERT INTO inbox_filters(app, subject) VALUES ('Gmail','Weekly Digest')")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("INSERT INTO inbox_filters(app, subject) VALUES ('Gmail','Weekly Digest')")
            self.assertEqual(db.execute("SELECT body FROM observations").fetchone(), ("Weekly Digest",))
            self.assertEqual(db.execute("SELECT saved, due_at, done FROM observation_work").fetchone(), (1, 9, 0))
            db.execute("INSERT INTO read_observations VALUES (1)")
            self.assertEqual(db.execute("SELECT observation_id FROM read_observations").fetchone(), (1,))
            self.assertEqual(db.execute("SELECT saved, due_at, done FROM observation_work").fetchone(), (1, 9, 0))
