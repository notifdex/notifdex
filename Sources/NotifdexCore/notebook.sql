-- Version 10 adds a personal notebook and titles for existing People notes.
ALTER TABLE person_notes ADD COLUMN title TEXT NOT NULL DEFAULT '';

CREATE TABLE note_folders (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK (length(trim(name)) > 0)
);

CREATE TABLE personal_notes (
    id TEXT PRIMARY KEY NOT NULL,
    folder_id TEXT REFERENCES note_folders(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL CHECK (length(body) > 0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL CHECK (updated_at >= created_at)
);
CREATE INDEX personal_notes_by_folder ON personal_notes(folder_id, updated_at DESC, id);
