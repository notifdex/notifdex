import sqlite3
import unittest
from pathlib import Path

SCHEMAS = Path(__file__).resolve().parents[1] / "Sources" / "NotifdexCore"


class NotificationHideRuleContractTests(unittest.TestCase):
    def test_subject_rules_migrate_to_body_and_match_fields_can_coexist(self):
        with sqlite3.connect(":memory:") as db:
            db.executescript((SCHEMAS / "filters.sql").read_text())
            stored = "Daily digest  "
            db.execute("INSERT INTO inbox_filters VALUES (9, 'Gmail', ?)", (stored,))
            db.executescript((SCHEMAS / "hide-rules.sql").read_text())

            query = "SELECT id, app, field, value FROM inbox_filters ORDER BY id"
            self.assertEqual(db.execute(query).fetchall(), [(9, "Gmail", "body", stored)])
            db.execute("INSERT INTO inbox_filters (app, field, value) VALUES ('Gmail', 'title', ?)", (stored,))
            db.execute("INSERT INTO inbox_filters (app, field, value) VALUES ('X', 'body', ?)", (stored,))
            for field in ("body", "subject"):
                with self.assertRaises(sqlite3.IntegrityError):
                    db.execute("INSERT INTO inbox_filters (app, field, value) VALUES ('Gmail', ?, ?)", (field, stored))
            self.assertEqual(db.execute(query).fetchall(), [
                (9, "Gmail", "body", stored),
                (10, "Gmail", "title", stored),
                (11, "X", "body", stored),
            ])
