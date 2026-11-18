-- The previous Gmail subject rule matched the notification's body.
ALTER TABLE inbox_filters RENAME TO legacy_subject_filters;
CREATE TABLE inbox_filters (
    id INTEGER PRIMARY KEY,
    app TEXT NOT NULL CHECK (length(app) > 0),
    field TEXT NOT NULL CHECK (field IN ('title', 'body')),
    value TEXT NOT NULL CHECK (length(value) > 0),
    UNIQUE (app, field, value)
);
INSERT INTO inbox_filters (id, app, field, value)
    SELECT id, app, 'body', subject FROM legacy_subject_filters WHERE app = 'Gmail';
DROP TABLE legacy_subject_filters;
