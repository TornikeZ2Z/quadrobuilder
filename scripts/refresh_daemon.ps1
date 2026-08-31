# QuadroBuilder refresh scheduler.
#
# Started hidden at logon by Startup\QuadroBuilderRefresh.vbs and stays resident.
# Refreshes three times a day, local time (machine is UTC+4 / Georgian Standard):
#
#   morning  - at logon, or from 06:00 if the machine was left on overnight
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

# Tell the user something needs them, WITHOUT blocking. A modal MessageBox called
# inline froze the whole scheduler until someone clicked OK - on an unattended
# machine that meant no slot ever ran again. The alert file is the durable record;
# the dialog is a detached process we never wait on.
function Notify-User([string]$title, [string]$body, [string]$onceKey) {
  try {
    Set-Content (Join-Path $LOGS 'ALERT.txt') `
      ("{0}`r`n`r`n{1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $body) -Encoding UTF8
  } catch { }
  if ($onceKey) {
    # One dialog per reason per day, not one per retry.
    $seen = Join-Path $LOGS ("alerted-{0}-{1}.txt" -f $onceKey, (Get-Date -Format 'yyyy-MM-dd'))
    if (Test-Path $seen) { return }
    try { Set-Content $seen 'x' -Encoding ASCII } catch { }
  }
  try {
    $msg = ($body -replace "'", "''")
    $cmd = "Add-Type -AssemblyName System.Windows.Forms; " +
           "[System.Windows.Forms.MessageBox]::Show('$msg','$title','OK','Warning') | Out-Null"
    Start-Process powershell -WindowStyle Hidden `
      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd | Out-Null
  } catch { }
}

# A refresh this recent means the data is already current; a slot falling due
# right after one would just repeat the same work. Kept well under the 5h gap
# between the 14:00 and 19:00 slots so a real slot is never swallowed - it only
# absorbs a logon that lands shortly before one.
$FRESH_MINUTES = 90
$RUN_TIMEOUT_MIN = 15          # a healthy run takes ~1 min
$MAX_ATTEMPTS = 4              # per slot per day, before giving up until the next slot
$BACKOFF_MIN = @(5, 15, 45)    # between attempts

function Get-LastRun {
  $f = Join-Path $LOGS 'last-run.txt'
  if (Test-Path $f) { try { return [datetime]::Parse((Get-Content $f -Raw).Trim()) } catch { } }
  return [datetime]'2000-01-01'
}

function Get-FailState([string]$slot) {
  $f = Join-Path $LOGS "slot-$slot.fail"
  if (Test-Path $f) {
    try {
      $p = ((Get-Content $f -Raw).Trim() -split '\|')
      return @{ count = [int]$p[0]; next = [datetime]::Parse($p[1]) }
    } catch { }
  }
  return @{ count = 0; next = [datetime]'2000-01-01' }
}
function Set-FailState([string]$slot, [int]$count, [datetime]$next) {
  try { Set-Content (Join-Path $LOGS "slot-$slot.fail") ("{0}|{1}" -f $count, $next.ToString('o')) -Encoding ASCII } catch { }
}
function Clear-FailState([string]$slot) {
  Remove-Item (Join-Path $LOGS "slot-$slot.fail") -Force -EA SilentlyContinue
}

# A lock left behind by a killed process used to disable the scheduler AND the
# manual command permanently and silently. It now carries its owner's PID and
# start time, and anything dead or older than the run timeout is cleared.
function Test-LockHeld([string]$lock) {
  if (-not (Test-Path $lock)) { return $false }
  try {
    $p = ((Get-Content $lock -Raw).Trim() -split '\|')
    $pidOwner = [int]$p[0]
    $since = [datetime]::Parse($p[1])
    $alive = $null -ne (Get-Process -Id $pidOwner -EA SilentlyContinue)
    if ($alive -and ((Get-Date) - $since).TotalMinutes -lt ($RUN_TIMEOUT_MIN * 2)) { return $true }
    Write-Log "clearing stale lock (pid=$pidOwner alive=$alive age=$([int]((Get-Date) - $since).TotalMinutes)m)"
  } catch {
    # An unreadable lock is most likely daily_refresh.cmd's simpler format, so
    # fall back to age: honour a recent one rather than barging in on a manual
    # run, but still clear one left behind by a killed process.
    $age = ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalMinutes
    if ($age -lt ($RUN_TIMEOUT_MIN * 2)) { return $true }
    Write-Log "clearing stale lock (unrecognised format, age $([int]$age)m)"
  }
  Remove-Item $lock -Force -EA SilentlyContinue
  return $false
}

function Invoke-Refresh([string]$slot) {
  $stamp = Join-Path $LOGS "slot-$slot.txt"
  $today = Get-Date -Format 'yyyy-MM-dd'

  $since = (Get-Date) - (Get-LastRun)
  # A negative span means the clock moved backwards; treat it as "not fresh"
  # rather than silently marking every slot done without refreshing anything.
  if ($since -ge [timespan]::Zero -and $since -lt [timespan]::FromMinutes($FRESH_MINUTES)) {
    Write-Log "[$slot] data refreshed under $FRESH_MINUTES min ago - marking slot done"
    Set-Content $stamp $today -Encoding ASCII
    return
  }

  $fail = Get-FailState $slot
  if ((Get-Date) -lt $fail.next) { return }        # still backing off, quietly

  $lock = Join-Path $LOGS 'refresh.lock'
  if (Test-LockHeld $lock) {
    Write-Log "[$slot] another refresh is running - will retry next tick"
    return
  }

  Write-Log "[$slot] starting refresh$(if ($fail.count) { " (attempt $($fail.count + 1))" })"
  Set-Content $lock ("{0}|{1}" -f $PID, (Get-Date).ToString('o')) -Encoding ASCII
  $runOut = Join-Path $LOGS "run-$slot.out"
  $runErr = Join-Path $LOGS "run-$slot.err"
  $rc = $null
  try {
    # Start-Process gives the export its own hidden console and a clean exit code.
    # Calling `& node ... *> file` instead breaks here: the daemon is launched
    # windowless by wscript, so it has no console for PowerShell to plumb the
    # native command's streams through, and the call fails instantly.
    $proc = Start-Process -FilePath 'node' `
              -ArgumentList (Join-Path $ROOT 'scripts/auto_export.mjs') `
              -WorkingDirectory $ROOT -WindowStyle Hidden -PassThru `
              -RedirectStandardOutput $runOut -RedirectStandardError $runErr
    # Touching .Handle caches it so .ExitCode is still readable after the process
    # ends. Without this ExitCode comes back EMPTY when -Wait is not used, every
    # failure looks alike, and the auth case gets retried pointlessly.
    $null = $proc.Handle
    # Never -Wait: a hung browser would hold the lock and block every slot forever.
    if ($proc.WaitForExit($RUN_TIMEOUT_MIN * 60 * 1000)) {
      $rc = $proc.ExitCode
    } else {
      Write-Log "[$slot] no response after $RUN_TIMEOUT_MIN min - killing the run"
      try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
      $rc = 1
    }
  } finally {
    Remove-Item $lock -Force -EA SilentlyContinue
  }
  Fold-Into-Log $runOut
  Fold-Into-Log $runErr
  if ($null -eq $rc) {
    Write-Log "[$slot] exit code unreadable - treating as transient"
    $rc = 1
  }

  if ($rc -eq 0) {
    Set-Content $stamp $today -Encoding ASCII
    Set-Content (Join-Path $LOGS 'last-run.txt') (Get-Date -Format 'o') -Encoding ASCII
    Clear-FailState $slot
    Remove-Item (Join-Path $LOGS 'ALERT.txt') -Force -EA SilentlyContinue
    Write-Log "[$slot] OK"
    return
  }

  # Exit codes come from auto_export.mjs: 2 = needs a human, 3 = page/selector,
  # anything else transient. Retrying an auth failure never once helped.
  if ($rc -eq 2) {
    Write-Log "[$slot] FAILED rc=2 (sign-in required) - not retrying today"
    Set-Content $stamp $today -Encoding ASCII       # stop hammering Optimo
    Notify-User 'QuadroBuilder' (
      "The Optimo session expired and the refresh could not sign back in.`n`n" +
      "To let it sign itself in from now on, run in the project folder:`n" +
      "  powershell -ExecutionPolicy Bypass -File scripts\optimo_credential.ps1 -Set`n`n" +
      "Or just log in once:`n  node scripts\auto_export.mjs --login") 'auth'
    return
  }

  $n = $fail.count + 1
  if ($n -ge $MAX_ATTEMPTS) {
    Write-Log "[$slot] FAILED rc=$rc - giving up after $n attempts, next slot will try again"
    Set-Content $stamp $today -Encoding ASCII
    Clear-FailState $slot
    Notify-User 'QuadroBuilder' (
      "The $slot data refresh failed $n times and has been stopped for now.`n`n" +
      "The next scheduled run will try again. See logs\refresh.log for the reason.") "fail-$slot"
    return
  }

  $wait = $BACKOFF_MIN[[Math]::Min($n - 1, $BACKOFF_MIN.Count - 1)]
  Set-FailState $slot $n ((Get-Date).AddMinutes($wait))
  Write-Log "[$slot] FAILED rc=$rc - retrying in $wait min (attempt $n of $MAX_ATTEMPTS)"
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

# Keep refresh.log from growing without bound across months of runs.
try {
  if ((Test-Path $LOG) -and (Get-Item $LOG).Length -gt 2MB) {
    Move-Item $LOG "$LOG.1" -Force -EA SilentlyContinue
  }
} catch { }

Write-Log "--- daemon started pid=$PID (slots: logon, 14:00, 19:00 local) ---"

# The morning slot is "at logon" on the first pass. After that the daemon is
# already resident, so on a machine left on overnight the slot would otherwise
# come due the moment the date rolls to midnight; from the second pass on it
# waits for 06:00 instead.
$firstPass = $true

try {
  # give the network a moment after logon
  Start-Sleep -Seconds 45

  while ($true) {
    try {
      $morningHour = if ($firstPass) { -1 } else { 6 }
      if (Slot-Due 'morning' $morningHour) { Invoke-Refresh 'morning' }
      if (Slot-Due 'afternoon' 14) { Invoke-Refresh 'afternoon' }
      if (Slot-Due 'evening'   19) { Invoke-Refresh 'evening' }
      $firstPass = $false
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
