-- Version 2 adds user state without changing captured evidence or links.
CREATE TABLE observation_work (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id),
    saved INTEGER NOT NULL DEFAULT 0 CHECK (saved IN (0, 1)),
    due_at REAL,
    done INTEGER NOT NULL DEFAULT 0 CHECK (done IN (0, 1)),
    CHECK (done = 0 OR due_at IS NOT NULL)
);
CREATE INDEX pending_follow_ups ON observation_work(due_at)
    WHERE due_at IS NOT NULL AND done = 0;
CREATE INDEX person_timeline ON person_observations(person_id, observation_id);
