@echo off
REM QuadroBuilder daily data refresh.
REM Launched at logon by Startup\QuadroBuilderRefresh.vbs (hidden window).
REM Exports the six Optimo reports, rebuilds the dashboard, publishes it.

setlocal EnableDelayedExpansion
set ROOT=C:\Users\user\Claude\QuadroBuilder
cd /d "%ROOT%" || exit /b 1
if not exist "logs" mkdir "logs"

for /f %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set TODAY=%%d

REM --- once per day: logging off and back on must not re-run it --------------
if exist "logs\last-success.txt" (
  set /p LAST=<"logs\last-success.txt"
  if "!LAST!"=="!TODAY!" goto :already
)

REM --- never let two runs share the browser profile --------------------------
if exist "logs\refresh.lock" goto :locked
echo running> "logs\refresh.lock"

REM --- let the network settle after logon ------------------------------------
REM (Windows timeout.exe can be shadowed by a POSIX timeout on PATH.)
powershell -NoProfile -Command "Start-Sleep -Seconds 45"

echo [%date% %time%] starting refresh >> "logs\refresh.log"
node "scripts\auto_export.mjs" >> "logs\refresh.log" 2>&1
set RC=!ERRORLEVEL!
del "logs\refresh.lock" 2>nul

if "!RC!"=="0" (
  echo !TODAY!> "logs\last-success.txt"
  echo [%date% %time%] OK >> "logs\refresh.log"
  exit /b 0
)

echo [%date% %time%] FAILED rc=!RC! >> "logs\refresh.log"
REM Most likely cause is an expired Optimo session - surface it, do not fail silently.
msg "%USERNAME%" /time:60 "QuadroBuilder refresh failed. If the Optimo session expired, run: node scripts\auto_export.mjs --login" 2>nul
exit /b !RC!

:already
echo [%date% %time%] already refreshed today (!TODAY!) - skipping >> "logs\refresh.log"
exit /b 0

:locked
echo [%date% %time%] another refresh is running - skipping >> "logs\refresh.log"
exit /b 0
