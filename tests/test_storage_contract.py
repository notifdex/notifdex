"""Exercise the shipped SQL with real SQLite, including process death and retries."""
import multiprocessing
from pathlib import Path
import sqlite3
import tempfile
import unittest

SCHEMA = Path(__file__).resolve().parents[1] / "Sources/NotifdexCore/schema.sql"
INSERT = """INSERT INTO observations
(source_id, source_event_id, run_id, captured_at, origin, title, subtitle, body,
 accessibility_description, parser_version)
VALUES ('device:notificationcenter', ?, 'run', 10, 'iphone', 'Alex', '', ?, ?, 1)
ON CONFLICT(source_id, source_event_id, origin, title, subtitle, body,
            accessibility_description, parser_version) DO NOTHING"""


def crash_during_write(path, ready):
    connection = sqlite3.connect(path)
    connection.execute("BEGIN IMMEDIATE")
    connection.execute(INSERT, ("uncommitted", "Hello", "X, Alex, Hello, from iPhone"))
    ready.send(True)
    ready.recv()  # Parent terminates this process before COMMIT.


class StorageContract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = str(Path(self.directory.name) / "test.db")
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA.read_text())
        self.db.execute("INSERT INTO capture_runs VALUES ('run', 1, 1, NULL)")
        self.db.commit()

    def record(self, event_id="a", body="Hello"):
        self.db.execute(INSERT, (event_id, body, f"X, Alex, {body}, from iPhone"))

    def count(self):
        return self.db.execute("SELECT count(*) FROM observations").fetchone()[0]

    def test_replay_then_identical_second_message(self):
        self.record()
        self.record()
        self.record("b")
        self.assertEqual(self.count(), 2)

    def test_changed_redacted_preview_is_a_revision(self):
        self.record(body="New message")
        self.record(body="Actual preview")
        self.assertEqual(self.count(), 2)

    def test_foreign_key_failure_rolls_back_whole_batch(self):
        with self.assertRaises(sqlite3.IntegrityError), self.db:
            self.record()
            self.db.execute("INSERT INTO person_observations VALUES (1, 'missing', 'manual')")
        self.assertEqual(self.count(), 0)

    def test_crash_before_commit_then_retry(self):
        parent, child = multiprocessing.Pipe()
        process = multiprocessing.Process(target=crash_during_write, args=(self.path, child))
        process.start()
        try:
            self.assertTrue(parent.poll(10), "Child did not reach uncommitted write")
            self.assertTrue(parent.recv())
        finally:
            process.terminate()
            process.join(10)
            parent.close()
            child.close()
        self.assertFalse(process.is_alive())
        self.assertEqual(self.count(), 0)
        self.record("uncommitted")
        self.db.commit()
        self.assertEqual(self.count(), 1)
        self.assertEqual(self.db.execute("PRAGMA integrity_check").fetchone()[0], "ok")

    def test_commit_survives_reopen_and_replay(self):
        self.record()
        self.db.commit()
        self.db.close()
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.record()
        self.assertEqual(self.count(), 1)

    def test_two_writers_retry_without_duplicates(self):
        other = sqlite3.connect(self.path, timeout=0)
        self.addCleanup(other.close)
        self.db.execute("BEGIN IMMEDIATE")
        self.record()
        with self.assertRaises(sqlite3.OperationalError):
            other.execute(INSERT, ("a", "Hello", "X, Alex, Hello, from iPhone"))
        self.db.commit()
        other.execute(INSERT, ("a", "Hello", "X, Alex, Hello, from iPhone"))
        other.commit()
        self.assertEqual(self.count(), 1)

    def test_display_name_does_not_automatically_create_person(self):
        self.record()
        self.assertEqual(self.db.execute("SELECT count(*) FROM people").fetchone()[0], 0)
        self.assertEqual(self.db.execute("SELECT count(*) FROM person_observations").fetchone()[0], 0)

    def test_gap_recovery_retains_evidence(self):
        self.db.execute("INSERT INTO coverage_gaps(run_id, reason, started_at) VALUES ('run', 'sleep', 2)")
        self.db.execute("UPDATE coverage_gaps SET ended_at=4, recovery_scanned_at=4")
        self.assertEqual(self.db.execute("SELECT reason, started_at, ended_at FROM coverage_gaps").fetchone(),
                         ("sleep", 2, 4))


if __name__ == "__main__":
    unittest.main()
