@echo off
setlocal
cd /d "%~dp0"

set "MONITOR_RELEASE_CHANNEL=release"
set "MONITOR_UPDATE_ARTIFACT_PREFIX="
set "UPDATE_R2_BUCKET=monitor-updates"

powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\wrappers\upload-update.ps1" -Channel release -LocalEnvPath "%~dp0packaging\local.release.env" %*
