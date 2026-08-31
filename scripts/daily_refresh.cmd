@echo off
REM QuadroBuilder - manual "refresh now".
REM
REM The scheduled runs (logon, 14:00, 19:00) are handled by scripts\refresh_daemon.ps1,
REM which Startup\QuadroBuilderRefresh.vbs launches hidden at logon. This file is only
REM for refreshing on demand - double-click it, or run it from a terminal.

setlocal
set ROOT=C:\Users\user\Claude\QuadroBuilder
cd /d "%ROOT%" || exit /b 1
if not exist "logs" mkdir "logs"

if exist "logs\refresh.lock" (
  echo A refresh is already running. Try again in a minute.
  exit /b 0
)
echo manual> "logs\refresh.lock"
node "scripts\auto_export.mjs"
set RC=%ERRORLEVEL%
del "logs\refresh.lock" 2>nul

if not "%RC%"=="0" echo.& echo Refresh failed. If the Optimo session expired, run:  node scripts\auto_export.mjs --login
exit /b %RC%
