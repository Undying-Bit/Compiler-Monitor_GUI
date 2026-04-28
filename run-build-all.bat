@echo off
setlocal
cd /d "%~dp0"
powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\wrappers\build-all.ps1" -Channel release -LocalEnvPath "%~dp0packaging\local.release.env" %*
