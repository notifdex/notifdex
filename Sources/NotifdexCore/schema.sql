CREATE TABLE IF NOT EXISTS capture_runs (
    id TEXT PRIMARY KEY,
    started_at REAL NOT NULL,
    heartbeat_at REAL NOT NULL,
    ended_at REAL,
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);

-- One observation is one distinct rendering of a source-scoped banner.
-- A changed preview under the same banner ID is retained as another revision.
CREATE TABLE IF NOT EXISTS observations (
    id INTEGER PRIMARY KEY,
    source_id TEXT NOT NULL CHECK (length(source_id) > 0),
    source_event_id TEXT NOT NULL CHECK (length(source_event_id) > 0),
    run_id TEXT NOT NULL REFERENCES capture_runs(id),
    captured_at REAL NOT NULL,
    origin TEXT NOT NULL CHECK (origin IN ('iphone', 'mac', 'unknown')),
    app_label TEXT,
    title TEXT NOT NULL,
    subtitle TEXT NOT NULL,
    body TEXT NOT NULL,
    accessibility_description TEXT NOT NULL,
    parser_version INTEGER NOT NULL,
    UNIQUE (source_id, source_event_id, origin, title, subtitle, body, accessibility_description, parser_version)
);

-- Recovery success never certifies that all notifications were delivered.
CREATE TABLE IF NOT EXISTS coverage_gaps (
    id INTEGER PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES capture_runs(id),
    reason TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    recovery_scanned_at REAL,
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_gap_per_run_reason
    ON coverage_gaps(run_id, reason) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS people (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS identities (
    id TEXT PRIMARY KEY,
    person_id TEXT REFERENCES people(id),
    platform TEXT NOT NULL,
    identifier TEXT NOT NULL,
    UNIQUE (platform, identifier)
);
CREATE TABLE IF NOT EXISTS person_observations (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id),
    person_id TEXT NOT NULL REFERENCES people(id),
    method TEXT NOT NULL CHECK (method IN ('manual', 'verified_identifier'))
);
