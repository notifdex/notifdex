-- Version 11 adds documents independently of both kinds of notes.
CREATE TABLE documents (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    body TEXT NOT NULL CHECK (length(body) > 0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL CHECK (updated_at >= created_at)
);
CREATE INDEX documents_by_edit ON documents(updated_at DESC, id);
