# MonitorSMS Windows Packaging (Compile Project)

This workspace packages the desktop app from the sibling source repo:

`C:\Users\Administrator\Code\Monitor GUI`

The packaging flow is now fail-closed:

- the MSI ships only a sanitized client `.env`
- update manifests and ZIPs must be detached-signed
- launcher builds require an embedded public verification key
- upload scripts no longer read repo-local secret files
- update uploads prune old remote update artifacts before uploading the new set

## Source Resolution

The packaging scripts resolve the app source root in this order:

1. `-SourceRoot`
2. `MONITOR_GUI_ROOT`
3. `C:\Users\Administrator\Code\Monitor GUI`

## Secure Config Model

The shipped desktop client supports only non-secret runtime configuration:

- `MONITOR_CHANNEL`
- `MONITOR_LOCAL_DATA_SUBDIR`
- `MONITOR_UPDATE_ARTIFACT_PREFIX`
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
.\packaging\build-bundle.ps1 -Output .\packaging\artifacts\MonitorSMS-<version>-setup-download-runtime.exe
.\packaging\build-bundle.ps1 -EmbedNet8Runtime -Output .\packaging\artifacts\MonitorSMS-<version>-setup-embedded-runtime.exe
```

## Installer Artifact Matrix

The packaging pipeline now emits four installer artifacts per channel/version:

- `<prefix>MonitorSMS-<version>.msi` (framework-dependent launcher, requires .NET 8 Desktop Runtime)
- `<prefix>MonitorSMS-<version>-selfcontained.msi` (self-contained launcher, no runtime prerequisite)
- `<prefix>MonitorSMS-<version>-setup-download-runtime.exe` (bootstrapper downloads/install runtime if needed, then runs MSI)
- `<prefix>MonitorSMS-<version>-setup-embedded-runtime.exe` (bootstrapper carries runtime for offline prerequisite install)

Default coworker installer: `*-setup-download-runtime.exe`.

Offline fallback order:

1. `*-setup-embedded-runtime.exe`
2. `*-selfcontained.msi`

Bundle gating behavior in `run-build-all.bat`:

- `release` channel fails the build if `MONITOR_NET8_RUNTIME_SHA256` is missing or setup bundle build fails.
- `development` channel warns and continues with MSI artifacts if setup bundle prerequisites are missing or bundle build fails.

## Root Batch Entrypoints

The root `.bat` files are one-click wrappers around `packaging\wrappers\*.ps1`.
They load `packaging\local.env` when present, while existing process environment variables take precedence.

Use `MONITOR_RELEASE_CHANNEL` (or `-Channel release|development`) to switch release/development packaging behavior.

Create local configuration from the template:

```powershell
Copy-Item .\packaging\local.env.template .\packaging\local.env
Copy-Item .\packaging\local.release.env.template .\packaging\local.release.env
Copy-Item .\packaging\local.development.env.template .\packaging\local.development.env
```

Then fill in the values needed by each workflow:

- `run-build-all.bat`: builds the PyInstaller app, signed update artifacts, framework-dependent MSI, self-contained MSI, and both setup EXEs.
- `run-build-launcher-msi.bat`: legacy name; now builds only the launcher.
- `run-upload-update.bat`: uploads existing signed update artifacts.

## Signed Update Artifacts

`make-update.ps1` now produces:

- `MonitorSMS-<version>.zip`
- `MonitorSMS-<version>.zip.sig`
- `MonitorSMS-<version>-app.zip`
- `MonitorSMS-<version>-app.zip.sig`
- `latest.json`
- `latest.json.sig`

When `-Channel development` is used, versioned update artifacts are prefixed with `development_`:

- `development_MonitorSMS-<version>.zip`
- `development_MonitorSMS-<version>.zip.sig`
- `development_MonitorSMS-<version>-app.zip`
- `development_MonitorSMS-<version>-app.zip.sig`
- `development_MonitorSMS-<version>.json`
- `development_MonitorSMS-<version>.json.sig`

It also archives rollback manifests under `packaging/artifacts/manifests/` as:

- `MonitorSMS-<version>.json`
- `MonitorSMS-<version>.json.sig`

The manifest includes:

```json
{
  "version": "0.2.10",
  "url": "https://updates.example.com/updates/MonitorSMS-0.2.10.zip",
  "sha256": "<zip-sha256>",
  "entry_exe": "MonitorSMS.exe",
  "signature_url": "https://updates.example.com/updates/MonitorSMS-0.2.10.zip.sig",
  "runtime_id": "<runtime-fingerprint>",
  "app_url": "https://updates.example.com/updates/MonitorSMS-0.2.10-app.zip",
  "app_sha256": "<app-zip-sha256>",
  "app_signature_url": "https://updates.example.com/updates/MonitorSMS-0.2.10-app.zip.sig"
}
```

The launcher verifies all detached signatures before trusting the manifest, the full ZIP, or the app-only ZIP.

`MonitorSMS-<version>-app.zip` contains:

- `MonitorSMS.exe`
- `_internal/station_monitor_assets/**`
- `_internal/base_library.zip`

`runtime_id` is a deterministic hash of `_internal/**`, excluding `_internal/station_monitor_assets/**` and `_internal/base_library.zip`.
The launcher uses the smaller `MonitorSMS-<version>-app.zip` only when the installed runtime fingerprint matches the manifest `runtime_id`; otherwise it falls back to the full ZIP automatically.

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
  last_good.json
  app-<version>\
    MonitorSMS.exe
    _internal\
%LOCALAPPDATA%\MonitorSMS\stage\
  <temporary downloads>
  health\
    candidate-health-<nonce>.json
```

## Worker / Broker Routing

The bundled Worker serves two logical routes from R2:

- `/updates/*` for `latest.json`, signatures, and ZIPs
- `/data/*` for `estaciones.db` and `reportes.db`

Release bucket bindings:

- `UPDATES_BUCKET=monitor-updates`
- `DATA_BUCKET=reportes-db`

Development bucket bindings:

- `UPDATES_BUCKET=development-updates`
- `DATA_BUCKET=development-db`

If `UPDATE_TOKEN` is configured in the Worker, only `Authorization: Bearer <token>` is accepted.
Query-string token auth is no longer supported.

## Uploading Updates

`upload-update.ps1` now uploads six files after pruning existing remote update artifacts in the same prefix:

- `latest.json`
- `latest.json.sig`
- `MonitorSMS-<version>.zip`
- `MonitorSMS-<version>.zip.sig`
- `MonitorSMS-<version>-app.zip`
- `MonitorSMS-<version>-app.zip.sig`

When `-Channel development` is used, the same set is uploaded with `development_` prefixes on versioned artifacts.

It validates that:

- `latest.json` version matches the ZIP name
- `latest.json.signature_url` matches the ZIP signature file name
- `latest.json.app_url` matches the app-only ZIP file name
- `latest.json.app_signature_url` matches the app-only ZIP signature file name
- `latest.json.runtime_id` is present when publishing the app-only ZIP
- the signature sidecar files exist before upload

Before upload, it deletes only recognized update artifacts in the configured prefix:

- `latest.json`
- `latest.json.sig`
- `MonitorSMS-<version>.zip`
- `MonitorSMS-<version>.zip.sig`
- `MonitorSMS-<version>-app.zip`
- `MonitorSMS-<version>-app.zip.sig`

It does not delete unrelated objects such as `/data/*` payloads or nested archive folders.

Credentials must come from environment variables or explicit parameters:

- `UPDATE_R2_ENDPOINT`
- `UPDATE_R2_ACCESS_KEY`
- `UPDATE_R2_SECRET_KEY`
- optional `UPDATE_R2_BUCKET` (defaults by channel: `monitor-updates` for release, `development-updates` for development)
- optional `UPDATE_R2_REGION`, `UPDATE_R2_SESSION_TOKEN`, `UPDATE_R2_PREFIX`

## Rollback Workflow

To roll back the remote update feed to an older packaged build:

1. Choose the archived manifest pair from `packaging/artifacts/manifests/`.
2. Copy `MonitorSMS-<version>.json` to `packaging/artifacts/latest.json`.
3. Copy `MonitorSMS-<version>.json.sig` to `packaging/artifacts/latest.json.sig`.
4. Ensure the matching `MonitorSMS-<version>.zip`, `MonitorSMS-<version>.zip.sig`, `MonitorSMS-<version>-app.zip`, and `MonitorSMS-<version>-app.zip.sig` are present in `packaging/artifacts/`.
5. Run `run-upload-update.bat` to prune the remote update artifacts and publish the rollback set.

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
6. Create the `development-updates` bucket before the first development-channel upload.
