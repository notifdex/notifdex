-- Version 5 adds private notes scoped to a person.
CREATE TABLE person_notes (
    id TEXT PRIMARY KEY NOT NULL,
    person_id TEXT NOT NULL REFERENCES people(id),
    body TEXT NOT NULL CHECK (length(body) > 0),
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL CHECK (updated_at >= created_at)
);
CREATE INDEX person_notes_by_person ON person_notes(person_id, created_at DESC, id);
