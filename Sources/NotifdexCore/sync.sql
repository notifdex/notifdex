-- Version 12 adds hybrid capture provenance, opt-in sync metadata, paired devices, and tombstones.
CREATE TABLE IF NOT EXISTS sync_state (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_devices (
    device_id TEXT PRIMARY KEY NOT NULL CHECK (length(device_id) > 0),
    display_name TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('mac', 'iphone', 'ipad', 'unknown')),
    status TEXT NOT NULL CHECK (status IN ('local_only', 'paired', 'revoked')),
    paired_at REAL,
    revoked_at REAL,
    last_synced_at REAL
);

CREATE TABLE IF NOT EXISTS sync_observation_links (
    observation_id INTEGER PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
    sync_uuid TEXT NOT NULL UNIQUE CHECK (length(sync_uuid) > 0),
    capture_channel TEXT NOT NULL CHECK (capture_channel IN ('macos_ax', 'ios_shortcuts', 'manual_test', 'remote_sync')),
    origin_device_id TEXT NOT NULL,
    logical_key TEXT NOT NULL CHECK (length(logical_key) > 0),
    workflow_version INTEGER NOT NULL DEFAULT 0,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sync_obs_logical_key
    ON sync_observation_links(logical_key);
CREATE INDEX IF NOT EXISTS idx_sync_obs_uuid
    ON sync_observation_links(sync_uuid);

CREATE TABLE IF NOT EXISTS sync_tombstones (
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    deleted_at REAL NOT NULL,
    PRIMARY KEY (entity_type, entity_id)
);
