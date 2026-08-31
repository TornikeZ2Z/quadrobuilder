# QuadroBuilder refresh scheduler.
#
# Started hidden at logon by Startup\QuadroBuilderRefresh.vbs and stays resident.
# Refreshes three times a day, local time (machine is UTC+4 / Georgian Standard):
#
#   morning  - at logon
#   14:00
#   19:00
#
# Task Scheduler needs elevation on this machine, so this loop does the timing.
# Slots are per-day stamped, so a slot missed while the PC was off runs on the
# next start (catch-up) rather than being skipped for the day.

$ErrorActionPreference = 'Stop'
# PS 7.3+ turns a non-zero exit from a native command into a thrown error under
# ErrorActionPreference='Stop'. We read $LASTEXITCODE ourselves, so switch it off
# (the variable does not exist on Windows PowerShell 5.1, which is harmless).
$PSNativeCommandUseErrorActionPreference = $false
$ROOT = 'C:\Users\user\Claude\QuadroBuilder'
$LOGS = Join-Path $ROOT 'logs'
$LOG  = Join-Path $LOGS 'refresh.log'
Set-Location $ROOT
if (-not (Test-Path $LOGS)) { New-Item -ItemType Directory $LOGS | Out-Null }

# --- one daemon only, however many times logon fires -------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\QuadroBuilderRefreshDaemon')
$owned = $false
try {
  $owned = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  # The previous daemon died without releasing it. WaitOne still hands us
  # ownership when it throws this, so we are the daemon now. Without this catch
  # a single crash would silently block every restart from here on.
  $owned = $true
}
if (-not $owned) { exit 0 }

# Logging must never be able to kill the scheduler. Anything holding the file
# open - Notepad, a tail -f, an antivirus scan - would otherwise take the daemon
# down on its next write. Retry briefly, then give up silently.
function Write-Raw([string]$text) {
  for ($i = 0; $i -lt 6; $i++) {
    try {
      $fs = [System.IO.File]::Open($LOG, 'Append', 'Write', 'ReadWrite')
      try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $fs.Write($bytes, 0, $bytes.Length)
      } finally { $fs.Dispose() }
      return
    } catch { Start-Sleep -Milliseconds 250 }
  }
}

function Write-Log($msg) {
  Write-Raw ("{0}  {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
}

# Copy a finished run-output file into the log and delete it. Guarded end to
# end: Get-Content -Raw returns $null for an empty file, and letting that (or
# anything else here) throw would skip the slot stamping below and leave the
# daemon re-running the export every five minutes.
function Fold-Into-Log([string]$file) {
  try {
    if (-not (Test-Path $file)) { return }
    $text = Get-Content $file -Raw
    if ($text -and $text.Trim()) { Write-Raw ($text + "`r`n") }
    Remove-Item $file -Force -EA SilentlyContinue
  } catch { }
}

# A refresh this recent means the data is already current; a slot falling due
# right after one would just repeat the same work. Kept well under the 5h gap
# between the 14:00 and 19:00 slots so a real slot is never swallowed - it only
# absorbs a logon that lands shortly before one.
$FRESH_MINUTES = 90

function Get-LastRun {
  $f = Join-Path $LOGS 'last-run.txt'
  if (Test-Path $f) { try { return [datetime]::Parse((Get-Content $f -Raw).Trim()) } catch { } }
  return [datetime]'2000-01-01'
}

function Invoke-Refresh($slot) {
  $stamp = Join-Path $LOGS "slot-$slot.txt"
  $today = Get-Date -Format 'yyyy-MM-dd'

  if ((Get-Date) - (Get-LastRun) -lt [timespan]::FromMinutes($FRESH_MINUTES)) {
    Write-Log "[$slot] data refreshed under $FRESH_MINUTES min ago - marking slot done"
    Set-Content $stamp $today -Encoding ASCII
    return
  }

  # Never let a manual run and a slot share the Chromium profile.
  $lock = Join-Path $LOGS 'refresh.lock'
  if (Test-Path $lock) {
    Write-Log "[$slot] another refresh is running - will retry next tick"
    return
  }

  Write-Log "[$slot] starting refresh"
  Set-Content $lock "daemon $PID" -Encoding ASCII
  # Send the export's own output to a private file first: redirecting straight
  # into refresh.log would fail the same way if anything else has it open.
  $runOut = Join-Path $LOGS "run-$slot.out"
  # Start-Process gives the export its own hidden console and a clean exit code.
  # Calling `& node ... *> file` instead breaks here: the daemon is launched
  # windowless by wscript, so it has no console for PowerShell to plumb the
  # native command's streams through, and the call fails instantly.
  $runErr = Join-Path $LOGS "run-$slot.err"
  try {
    $proc = Start-Process -FilePath 'node' `
              -ArgumentList (Join-Path $ROOT 'scripts/auto_export.mjs') `
              -WorkingDirectory $ROOT -WindowStyle Hidden -Wait -PassThru `
              -RedirectStandardOutput $runOut -RedirectStandardError $runErr
    $rc = $proc.ExitCode
  } finally {
    Remove-Item $lock -Force -EA SilentlyContinue
  }
  Fold-Into-Log $runOut
  Fold-Into-Log $runErr

  if ($rc -eq 0) {
    Set-Content $stamp $today -Encoding ASCII
    Set-Content (Join-Path $LOGS 'last-run.txt') (Get-Date -Format 'o') -Encoding ASCII
    Write-Log "[$slot] OK"
  } else {
    Write-Log "[$slot] FAILED rc=$rc"
    # Do NOT stamp the slot: a transient failure should retry on the next tick.
    # Most likely cause is an expired Optimo session, which needs a human.
    try {
      Add-Type -AssemblyName System.Windows.Forms
      [System.Windows.Forms.MessageBox]::Show(
        "QuadroBuilder refresh failed.`n`nIf the Optimo session expired, run:`n  node scripts\auto_export.mjs --login",
        'QuadroBuilder', 'OK', 'Warning') | Out-Null
    } catch { }
  }
}

# $hour of -1 means "at logon" rather than a clock time. The types matter:
# untyped, PowerShell binds -1 as the string '-1' and the comparison below
# only works by accident of string ordering.
function Slot-Due([string]$slot, [int]$hour) {
  $stamp = Join-Path $LOGS "slot-$slot.txt"
  $today = Get-Date -Format 'yyyy-MM-dd'
  if (Test-Path $stamp) { if ((Get-Content $stamp -Raw).Trim() -eq $today) { return $false } }
  if ($hour -lt 0) { return $true }                 # -1 = at logon
  return (Get-Date).Hour -ge $hour
}

Write-Log "--- daemon started pid=$PID (slots: logon, 14:00, 19:00 local) ---"

try {
  # give the network a moment after logon
  Start-Sleep -Seconds 45

  while ($true) {
    try {
      if (Slot-Due 'morning'   -1) { Invoke-Refresh 'morning' }
      if (Slot-Due 'afternoon' 14) { Invoke-Refresh 'afternoon' }
      if (Slot-Due 'evening'   19) { Invoke-Refresh 'evening' }
    } catch {
      Write-Log "slot error: [$($_.Exception.GetType().Name)] $($_.Exception.Message)"
      Write-Log "slot error at: $($_.InvocationInfo.PositionMessage -replace '\s+', ' ')"
    }
    Start-Sleep -Seconds 300
  }
} catch {
  # anything that escapes the loop is fatal - record it, do not vanish silently
  Write-Log "FATAL: $($_.Exception.Message)"
  Write-Log "FATAL at: $($_.InvocationInfo.PositionMessage -replace "`r?`n", ' ')"
  throw
} finally {
  Write-Log "--- daemon exiting pid=$PID ---"
}
