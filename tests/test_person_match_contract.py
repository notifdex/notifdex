"""Check that version four gives each app/title at most one destination."""
import sqlite3
import unittest

from test_storage_contract import SCHEMA


class PersonMatchContract(unittest.TestCase):
    def test_unique_destination_and_preserved_manual_link(self):
        db = sqlite3.connect(":memory:")
        self.addCleanup(db.close)
        db.execute("PRAGMA foreign_keys = ON")
        for name in ["schema.sql", "rolodex.sql", "filters.sql"]:
            db.executescript(SCHEMA.with_name(name).read_text())
        db.executescript("""
            INSERT INTO capture_runs VALUES ('run', 1, 1, NULL);
            INSERT INTO observations VALUES (1,'device','alert','run',2,'iphone','X','Alex','','Hi','fixture',1);
            INSERT INTO people VALUES ('alex', 'Alex'), ('other', 'Alex');
            INSERT INTO person_observations VALUES (1, 'other', 'manual');
        """)
        db.executescript(SCHEMA.with_name("person-matches.sql").read_text())
        db.execute("INSERT INTO person_match_rules VALUES ('rule','X','Alex','alex',0)")
        with self.assertRaises(sqlite3.IntegrityError):
            db.execute("INSERT INTO person_match_rules VALUES ('conflict','X','Alex','other',0)")
        db.execute("DELETE FROM person_match_rules")
        self.assertEqual(db.execute("SELECT person_id FROM person_observations WHERE observation_id=1").fetchone(), ("other",))
