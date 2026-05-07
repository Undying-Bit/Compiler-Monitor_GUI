CREATE TABLE IF NOT EXISTS telemetry_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at TEXT NOT NULL,
    event TEXT NOT NULL,
    installation_id TEXT NOT NULL,
    launcher_session_id TEXT NOT NULL,
    launcher_version TEXT,
    channel TEXT,
    user_name TEXT,
    user_domain TEXT,
    os_description TEXT,
    os_architecture TEXT,
    payload_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_telemetry_installation_received
ON telemetry_events (installation_id, received_at);

CREATE INDEX IF NOT EXISTS idx_telemetry_event_received
ON telemetry_events (event, received_at);

CREATE INDEX IF NOT EXISTS idx_telemetry_user_received
ON telemetry_events (user_name, received_at);
