-- Version 13 upgrades inbox_filters to support app-level hide rules, enable/disable toggle, and LWW timestamps.
ALTER TABLE inbox_filters RENAME TO v12_inbox_filters;
CREATE TABLE inbox_filters (
    id INTEGER PRIMARY KEY,
    app TEXT NOT NULL CHECK (length(app) > 0),
    field TEXT NOT NULL CHECK (field IN ('title', 'body', 'app')),
    value TEXT NOT NULL CHECK (length(value) > 0),
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    updated_at REAL NOT NULL DEFAULT 0,
    UNIQUE (app, field, value)
);
INSERT INTO inbox_filters (id, app, field, value, enabled, updated_at)
    SELECT id, app, field, value, 1, 0 FROM v12_inbox_filters;
DROP TABLE v12_inbox_filters;
