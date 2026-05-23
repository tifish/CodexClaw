@echo off
setlocal

cd /d "%~dp0"

where npm >nul 2>nul
if errorlevel 1 (
  echo [ERROR] npm was not found in PATH.
  echo Install Node.js 20+ first, then rerun this script.
  exit /b 1
)

if not exist "node_modules" (
  echo Dependencies are missing. Running setup.cmd...
  call "%~dp0setup.cmd"
  if errorlevel 1 (
    echo [ERROR] setup.cmd failed.
    exit /b 1
  )
)

if /I "%~1"=="dev" (
  echo Starting CodexClaw in dev mode...
  call npm run dev
  exit /b %errorlevel%
)

echo Starting CodexClaw...
call npm run start
exit /b %errorlevel%
