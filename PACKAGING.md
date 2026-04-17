# MonitorSMS Windows Packaging (Compile Project)

This workspace packages the desktop app from the sibling source repo:

`C:\Users\Administrator\Code\Monitor GUI`

The packaging flow is now fail-closed:

- the MSI ships only a sanitized client `.env`
- update manifests and ZIPs must be detached-signed
- launcher builds require an embedded public verification key
- upload scripts no longer read repo-local secret files
- update uploads no longer purge the bucket

## Source Resolution

The packaging scripts resolve the app source root in this order:

1. `-SourceRoot`
2. `MONITOR_GUI_ROOT`
3. `C:\Users\Administrator\Code\Monitor GUI`

## Secure Config Model

The shipped desktop client supports only non-secret runtime configuration:

- `MONITOR_PRIMARY_BASE_URL`
- `MONITOR_BACKUP_BASE_URL`
- `MONITOR_KEY_ESTACIONES`
- `MONITOR_KEY_REPORTES`
- `MONITOR_UPDATE_MANIFEST_URL`
- `MONITOR_DEBUG_PANEL_VISIBLE`

Do not put `MONITOR_R2_*`, `MONITOR_B2_*`, `UPDATE_R2_*`, access keys, secret keys, or session tokens in the client config.
Those values must stay in CI, release automation, or server-side broker infrastructure only.

## Quick Build

Install PyInstaller into the app repo venv:

```powershell
& "C:\Users\Administrator\Code\Monitor GUI\.venv\Scripts\python.exe" -m pip install pyinstaller
```

Build the PyInstaller app:

```powershell
.\packaging\build-app.ps1
```

Generate an update-signing key pair once, outside the repo:

```powershell
dotnet run --project .\packaging\signer\MonitorSMSSigner.csproj -- keygen --private C:\secure\monitor-update-private.pem --public C:\secure\monitor-update-public.pem
```

Build the launcher with an embedded update-signing public key:

```powershell
$env:MONITOR_UPDATE_SIGNING_PUBLIC_KEY_PATH="C:\secure\monitor-update-public.pem"
.\packaging\build-launcher.ps1 -FrameworkDependent
```

Create signed update artifacts:

```powershell
$env:MONITOR_UPDATE_SIGNING_KEY_PATH="C:\secure\monitor-update-private.pem"
.\packaging\make-update.ps1 -BaseUrl https://updates.example.com/updates
```

Build the MSI with a sanitized client config generated from environment variables:

```powershell
$env:MONITOR_PRIMARY_BASE_URL="https://updates.example.com/data"
$env:MONITOR_BACKUP_BASE_URL="https://backup.example.com/data"
$env:MONITOR_UPDATE_MANIFEST_URL="https://updates.example.com/updates/latest.json"
.\packaging\build-msi.ps1
```

Build the setup bundle with a pinned runtime hash:

```powershell
$env:MONITOR_NET8_RUNTIME_SHA256="<official-runtime-sha256>"
.\packaging\build-bundle.ps1
```

## Root Batch Entrypoints

The root `.bat` files are one-click wrappers around `packaging\wrappers\*.ps1`.
They load `packaging\local.env` when present, while existing process environment variables take precedence.

Create local configuration from the template:

```powershell
Copy-Item .\packaging\local.env.template .\packaging\local.env
```

Then fill in the values needed by each workflow:

- `run-build-all.bat`: builds the PyInstaller app, launcher, signed update artifacts, and MSI.
- `run-build-launcher-msi.bat`: legacy name; now builds only the launcher.
- `run-upload-update.bat`: uploads existing signed update artifacts.

## Signed Update Artifacts

`make-update.ps1` now produces:

- `MonitorSMS-<version>.zip`
- `MonitorSMS-<version>.zip.sig`
- `latest.json`
- `latest.json.sig`

The manifest includes:

```json
{
  "version": "0.2.10",
  "url": "https://updates.example.com/updates/MonitorSMS-0.2.10.zip",
  "sha256": "<zip-sha256>",
  "entry_exe": "MonitorSMS.exe",
  "signature_url": "https://updates.example.com/updates/MonitorSMS-0.2.10.zip.sig"
}
```

The launcher verifies both detached signatures before trusting the manifest or ZIP.

## MSI Contents

The per-user MSI installs under `%LOCALAPPDATA%\Programs\MonitorSMS` and contains:

- `MonitorSMSLauncher.exe`
- a generated `.env` containing only the allowlisted non-secret client settings

The MSI no longer packages a developer `.env`, encrypted env file, or cloud credentials.

## Runtime Layout

Expected install/runtime layout:

```text
%LOCALAPPDATA%\Programs\MonitorSMS\
  MonitorSMSLauncher.exe
  .env
%LOCALAPPDATA%\MonitorSMS\logs\
  launcher.log
  monitor_sms.log
%LOCALAPPDATA%\MonitorSMS\runtime\
  current.json
  app-<version>\
    MonitorSMS.exe
    _internal\
%LOCALAPPDATA%\MonitorSMS\stage\
  <temporary downloads>
```

## Worker / Broker Routing

The bundled Worker serves two logical routes from R2:

- `/updates/*` for `latest.json`, signatures, and ZIPs
- `/data/*` for `estaciones.db` and `reportes.db`

If `UPDATE_TOKEN` is configured in the Worker, only `Authorization: Bearer <token>` is accepted.
Query-string token auth is no longer supported.

## Uploading Updates

`upload-update.ps1` now uploads four files:

- `latest.json`
- `latest.json.sig`
- `MonitorSMS-<version>.zip`
- `MonitorSMS-<version>.zip.sig`

It validates that:

- `latest.json` version matches the ZIP name
- `latest.json.signature_url` matches the ZIP signature file name
- the signature sidecar files exist before upload

It does not delete existing bucket contents.

Credentials must come from environment variables or explicit parameters:

- `UPDATE_R2_ENDPOINT`
- `UPDATE_R2_BUCKET`
- `UPDATE_R2_ACCESS_KEY`
- `UPDATE_R2_SECRET_KEY`
- optional `UPDATE_R2_REGION`, `UPDATE_R2_SESSION_TOKEN`, `UPDATE_R2_PREFIX`

## Build Hygiene

- Generated version metadata is written under `.tmp\generated\` instead of mutating tracked files.
- `.env`, `.env.enc`, `.wix`, launcher `bin/` / `obj/`, `.pdb`, `.wixpdb`, and cabinet outputs are ignored.
- `build-launcher.ps1`, `build-msi.ps1`, and `build-bundle.ps1` now stop on tool failures instead of continuing after a bad `dotnet` or WiX invocation.

## Release Requirements

Before shipping a build:

1. Rotate any previously exposed R2/B2/update credentials.
2. Store update-signing private keys outside the repo, preferably in CI secret storage.
3. Verify the generated installer `.env` contains only allowlisted non-secret keys.
4. Upload signed update artifacts through the brokered update service path.
5. Keep the desktop client free of direct cloud credentials.
