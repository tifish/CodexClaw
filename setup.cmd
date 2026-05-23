@echo off
setlocal

cd /d "%~dp0"

where npm >nul 2>nul
if errorlevel 1 (
  echo [ERROR] npm was not found in PATH.
  echo Install Node.js 20+ first, then rerun this script.
  exit /b 1
)

echo Installing dependencies...
call npm install
if errorlevel 1 (
  echo [ERROR] npm install failed.
  exit /b 1
)

if not exist ".env" if exist ".env.example" (
  echo Creating .env from .env.example...
  copy /Y ".env.example" ".env" >nul
)

echo Done.
exit /b 0
