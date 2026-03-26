# Cloudflare Worker for Update URLs

This worker serves `latest.json` and versioned ZIPs from an R2 bucket.

## Setup

1. Create an R2 bucket (example: `station-monitor-updates`).
2. Upload update files to the bucket:

```
latest.json
MonitorSMS-0.2.6.zip
```

3. Install Wrangler and configure your account.
4. Update `wrangler.toml`:
   - `account_id`
   - `bucket_name`
   - optional `UPDATE_TOKEN`

## Deploy

```powershell
wrangler deploy
```

## URL Usage

If your worker is bound to a custom domain like `https://updates.example.com/*`,
then:

- `MONITOR_UPDATE_MANIFEST_URL` should be
  `https://updates.example.com/latest.json`
- the manifest `url` should be
  `https://updates.example.com/MonitorSMS-0.2.6.zip`

## Optional Auth

Set `UPDATE_TOKEN` in `wrangler.toml` to require a token.
Clients can send:

- `Authorization: Bearer <token>`
- or `?token=<token>` in the URL
