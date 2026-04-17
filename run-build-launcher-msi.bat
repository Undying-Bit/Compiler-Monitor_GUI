@echo off
setlocal
cd /d "%~dp0"
powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\wrappers\build-launcher-msi.ps1" %*
