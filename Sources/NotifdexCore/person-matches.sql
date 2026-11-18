-- Rules are user-approved projections. Existing manual links stay authoritative.
CREATE TABLE person_match_rules (
    id TEXT PRIMARY KEY NOT NULL,
    app TEXT NOT NULL CHECK (length(app) > 0),
    title TEXT NOT NULL CHECK (length(title) > 0),
    person_id TEXT NOT NULL REFERENCES people(id),
    after_observation_id INTEGER NOT NULL CHECK (after_observation_id >= 0),
    UNIQUE (app, title)
);
CREATE INDEX person_match_rules_by_person ON person_match_rules(person_id);
CREATE INDEX observations_by_title ON observations(title);

-- An explicit unlink blocks both the current rule and later rules.
CREATE TABLE person_match_exclusions (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id)
);
