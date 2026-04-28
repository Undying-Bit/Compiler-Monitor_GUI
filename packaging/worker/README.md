# MonitorSMS Update / Data Worker

This Worker brokers signed update artifacts and database downloads from R2 without shipping long-lived cloud credentials to the desktop client.

## Routes

- `/updates/latest.json`
- `/updates/latest.json.sig`
- `/updates/MonitorSMS-<version>.zip`
- `/updates/MonitorSMS-<version>.zip.sig`
- `/estaciones.db`
- `/reportes.db`
- `/data/estaciones.db`
- `/data/reportes.db`

## Configuration

`wrangler.toml` variables:

- `UPDATES_PREFIX`
- `DATA_PREFIX`
- optional `UPDATE_TOKEN`

R2 bindings:

- `UPDATES_BUCKET`
- `DATA_BUCKET`

Default release bucket mapping:

- `UPDATES_BUCKET=monitor-updates`
- `DATA_BUCKET=reportes-db`

Development environment bucket mapping:

- `UPDATES_BUCKET=development-updates`
- `DATA_BUCKET=development-db`

If `UPDATE_TOKEN` is set, requests must include:

```http
Authorization: Bearer <token>
```

Query-string token authentication is intentionally unsupported.

## Client Settings

Use public, non-secret client config values:

- `MONITOR_UPDATE_MANIFEST_URL=https://updates.example.com/updates/latest.json`
- `MONITOR_PRIMARY_BASE_URL=https://updates.example.com/data`
- `MONITOR_BACKUP_BASE_URL=https://backup.example.com/data`

The desktop client must not contain `MONITOR_R2_*`, `MONITOR_B2_*`, or `UPDATE_R2_*` secrets.

## Integrity

- `latest.json` and update ZIPs are expected to have detached `.sig` sidecars.
- ZIP uploads should include `sha256` object metadata so the Worker can forward it as `x-monitor-sha256`.
