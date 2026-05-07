ALTER TABLE telemetry_events ADD COLUMN user_name TEXT;
ALTER TABLE telemetry_events ADD COLUMN user_domain TEXT;
ALTER TABLE telemetry_events ADD COLUMN os_description TEXT;
ALTER TABLE telemetry_events ADD COLUMN os_architecture TEXT;

CREATE INDEX IF NOT EXISTS idx_telemetry_user_received
ON telemetry_events (user_name, received_at);
