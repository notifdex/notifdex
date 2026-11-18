CREATE TABLE flagged_observations (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id)
);

CREATE INDEX observations_by_capture ON observations(captured_at, id);
