@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0service-manager.ps1" -Action uninstall
exit /b %errorlevel%
