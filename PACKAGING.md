# MonitorSMS Windows Packaging (Compile Project)

This guide documents the recommended Windows packaging, update, and installer flow.
It assumes a dedicated compile project at:

C:\Users\Administrator\Code\Compile-Monitor_GUI

The scripts resolve the app source root in this order:

1. `-SourceRoot` parameter
2. `MONITOR_GUI_ROOT` environment variable
3. Sibling folder: `C:\Users\Administrator\Code\Monitor GUI`

## Quick Build

Install PyInstaller into the app repo venv:

```powershell
& "C:\Users\Administrator\Code\Monitor GUI\.venv\Scripts\python.exe" -m pip install pyinstaller
```

Build the app (one-folder):

```powershell
.\packaging\build-app.ps1
```

Build the launcher (native, self-contained):

```powershell
.\packaging\build-launcher.ps1
```

Create the update zip and manifest (for upload; not required for MSI build):

```powershell
.\packaging\make-update.ps1 -BaseUrl https://example.com
```

Build the per-user MSI (WiX v4):

```powershell
.\packaging\build-msi.ps1
```

Override the source repo location when needed:

```powershell
.\packaging\build-app.ps1 -SourceRoot "C:\Path\To\Monitor GUI"
```

MSI prerequisite:

- Install the .NET 8 SDK (global.json pins launcher builds to 8.x)
- Install WiX as a global .NET tool: `dotnet tool install --global wix`
- Open a new PowerShell window so `wix` is on `PATH`

## Icons, Version Info, Manifest

- `packaging\app.manifest` sets `asInvoker` so the app does not trigger UAC prompts.
- `packaging\version_info_app.txt` holds Windows version metadata for the PyInstaller app.
- The launcher version metadata comes from `pyproject.toml` via `build-launcher.ps1`.
- Place `packaging\app.ico` and `packaging\launcher.ico` to brand the exe files (optional).
- If `packaging\app.ico` exists, the MSI will use it as the Add/Remove Programs icon.

Update the version strings in `version_info_app.txt` whenever you bump `pyproject.toml`.

## Expected Output Structure

Compile project output:

```
dist\
  MonitorSMS\
    MonitorSMS.exe
    _internal\
  MonitorSMSLauncher\
    MonitorSMSLauncher.exe
.pyinstaller\
  build\
  spec\
packaging\
  artifacts\
```

Note: `packaging\build-app.ps1` trims unused Qt modules (including WebEngine/QML)
and removes Qt translation/QML/plugin payloads to keep update ZIPs small. If you
add new Qt features that require those modules, update the exclude list and
prune step in that script.

Run the exe from `dist\MonitorSMS\MonitorSMS.exe` only.
Do not run the copy under `.pyinstaller\build`; that directory contains intermediate artifacts.

Recommended per-user install layout:

```
%LOCALAPPDATA%\Programs\MonitorSMS\
  MonitorSMSLauncher.exe
  .env
  MonitorSMS-0.2.6.zip (optional baseline)
%LOCALAPPDATA%\MonitorSMS\logs\
  monitor_sms.log
  launcher.log
%LOCALAPPDATA%\MonitorSMS\runtime\
  current.json
  app-0.2.6\
    MonitorSMS.exe
    _internal\
%LOCALAPPDATA%\MonitorSMS\stage\
  <temp extract folders>
%LOCALAPPDATA%\MonitorSMS\tmp\
  monitor_sms_*
```

Thin MSI installs do not include a baseline ZIP; the first run downloads from the update manifest.

## Config Files and Secrets

Keep `.env` next to the launcher exe. The launcher and app read `.env` from the working directory.
MSI shortcuts should use the install directory as the "Start in" path.
`build-msi.ps1` will package `packaging\.env` if it exists; otherwise it falls back to `packaging\env.template`.

Packaging scripts load environment from:

- `C:\Users\Administrator\Code\Compile-Monitor_GUI\.env`
- `C:\Users\Administrator\Code\Compile-Monitor_GUI\packaging\.env`

## Update Manifest (HTTP/Cloud)

The launcher looks at `MONITOR_UPDATE_MANIFEST_URL` in `.env`. Example:

```
 MONITOR_UPDATE_MANIFEST_URL=https://example.com/latest.json
```

To disable update checks for a run, set:

```
MONITOR_SKIP_UPDATE=true
```

The manifest format:

```json
{
  "version": "0.2.6",
  "url": "https://example.com/MonitorSMS-0.2.6.zip",
  "sha256": "abc123..."
}
```

Run `.\packaging\make-update.ps1` to generate a ZIP and `latest.json`.

For MSI installs, keep the ZIP next to the launcher when available. The launcher
downloads the ZIP to a staging folder and then copies only `MonitorSMS.exe` and
`_internal` into `%LOCALAPPDATA%\MonitorSMS\runtime\app-<version>`.

## Cloudflare Worker (R2 URLs)

See `packaging/worker/README.md` for a ready-to-deploy Worker that serves
`latest.json` and ZIPs from R2. With an empty Worker prefix, the R2 objects live at bucket root:

```
latest.json
MonitorSMS-0.2.6.zip
```

When deployed to a domain like `https://updates.example.com/*`:

- `MONITOR_UPDATE_MANIFEST_URL` should be
  `https://updates.example.com/latest.json`
- `latest.json` should include:
  `https://updates.example.com/MonitorSMS-0.2.6.zip`

## Upload Updates (S3 API)

Files larger than 300 MB should be uploaded using the S3 Compatibility API. The upload
script purges the updates bucket first, then uploads `latest.json` plus the ZIP whose
version matches `latest.json`.

Steps:
- Run `.\packaging\make-update.ps1` to generate `packaging\artifacts\latest.json`
  and `MonitorSMS-<version>.zip`.
- Set the `UPDATE_R2_*` values in `.env` or `packaging\.env` (compile project).
- Run:

```powershell
.\packaging\upload-update.ps1
```

Notes:
- The script validates that `latest.json.url` ends with `MonitorSMS-<version>.zip`
  and fails if it does not.
- The purge always deletes all objects in the bucket, even when a prefix is used
  for uploads. Use a dedicated updates bucket.
- To upload under a prefix, set `UPDATE_R2_PREFIX` or pass `-Prefix`. Ensure the
  `-BaseUrl` used by `make-update.ps1` includes that prefix so `latest.json` matches.

## Per-User MSI Notes

A per-user MSI installs under `%LOCALAPPDATA%\Programs\MonitorSMS` and writes only to HKCU.
This avoids UAC prompts and keeps installs scoped to each user account.
Use WiX v4 or Advanced Installer to package:

- `MonitorSMSLauncher.exe`
- `packaging\.env` copied to `.env` during install when present
- the `.env` file is not overwritten on upgrades (so secrets remain intact)
- desktop and Start Menu shortcuts that set "Start in" to the install folder
- `MONITOR_UPDATE_MANIFEST_URL` must be set in the packaged `.env`

## SmartScreen and Signing

Without a trusted code-signing certificate, SmartScreen and "Unknown Publisher" prompts are expected.
Reputation and code signing are the normal ways to reduce those warnings.
