-- Version 8 adds local template definitions, version pins, and manual progress.
CREATE TABLE relationship_templates (
    template_id TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version > 0),
    definition TEXT NOT NULL,
    PRIMARY KEY (template_id, version)
);

CREATE TABLE person_templates (
    person_id TEXT NOT NULL PRIMARY KEY REFERENCES people(id) ON DELETE CASCADE,
    template_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    stage_id TEXT NOT NULL,
    FOREIGN KEY (template_id, version) REFERENCES relationship_templates(template_id, version)
);

CREATE TABLE person_template_milestones (
    person_id TEXT NOT NULL REFERENCES person_templates(person_id) ON DELETE CASCADE,
    milestone_id TEXT NOT NULL,
    completed INTEGER NOT NULL CHECK (completed IN (0, 1)),
    PRIMARY KEY (person_id, milestone_id)
);
