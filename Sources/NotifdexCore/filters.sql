CREATE TABLE inbox_filters (
    id INTEGER PRIMARY KEY,
    app TEXT NOT NULL CHECK (length(app) > 0),
    subject TEXT NOT NULL CHECK (length(subject) > 0),
    UNIQUE (app, subject)
);

CREATE TABLE hidden_observations (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id)
);

CREATE TABLE read_observations (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id)
);
