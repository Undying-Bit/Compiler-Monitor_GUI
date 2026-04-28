@echo off
setlocal
cd /d "%~dp0"
powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\wrappers\build-all.ps1" -Channel development -LocalEnvPath "%~dp0packaging\local.development.env" %*
