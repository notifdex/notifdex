-- Version 9 keeps People membership and manual alert routing independent.
CREATE TABLE workspaces (
    id TEXT NOT NULL PRIMARY KEY,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK (length(name) > 0)
);

CREATE TABLE person_workspaces (
    person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    PRIMARY KEY (person_id, workspace_id)
);
CREATE INDEX people_by_workspace ON person_workspaces(workspace_id, person_id);

CREATE TABLE observation_workspaces (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE
);
CREATE INDEX observations_by_workspace ON observation_workspaces(workspace_id, observation_id);
