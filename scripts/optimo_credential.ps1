<#
  QuadroBuilder - Optimo credential store.

  Lets the scheduled export sign itself back in when the Optimo session expires,
  without the password ever being written down in the repo or handed to anyone.

  You type the password into Windows' own credential prompt. It is encrypted with
  DPAPI, which ties the ciphertext to YOUR Windows account on THIS machine: copied
  to another PC, or opened by another user here, it is unreadable. It is stored
  outside the repository so it can never be committed.

      .\scripts\optimo_credential.ps1 -Set       # store / replace it (prompts)
      .\scripts\optimo_credential.ps1 -Status    # is one stored? (never shows the password)
      .\scripts\optimo_credential.ps1 -Remove    # delete it

  -Emit is used by scripts/auto_export.mjs. It writes the credential to stdout as
  JSON for the parent process and is not meant to be run by hand.
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
  [Parameter(ParameterSetName = 'Set')]    [switch]$Set,
  [Parameter(ParameterSetName = 'Status')] [switch]$Status,
  [Parameter(ParameterSetName = 'Remove')] [switch]$Remove,
  [Parameter(ParameterSetName = 'Emit')]   [switch]$Emit
)

$ErrorActionPreference = 'Stop'

# Deliberately outside the repo: nothing here can be caught by a stray `git add`.
$Dir  = Join-Path $env:LOCALAPPDATA 'QuadroBuilder'
$Path = Join-Path $Dir 'optimo.cred.xml'

function Read-Cred {
  if (-not (Test-Path $Path)) { return $null }
  try { return Import-Clixml $Path } catch { return $null }
}

switch ($PSCmdlet.ParameterSetName) {

  'Set' {
    Write-Host ''
    Write-Host '  Optimo sign-in for the automated refresh' -ForegroundColor Cyan
    Write-Host '  The password is encrypted with your Windows account and stored at:'
    Write-Host "    $Path"
    Write-Host '  It is never written to the repo, the logs, or the terminal.'
    Write-Host ''
    # Windows' own masked prompt. The password exists here as a SecureString and
    # goes straight into the DPAPI-encrypted file.
    $cred = Get-Credential -Message 'Optimo (dashboard.optimo.ge) sign-in'
    if (-not $cred -or [string]::IsNullOrWhiteSpace($cred.UserName)) {
      Write-Host '  cancelled - nothing stored.' -ForegroundColor Yellow; exit 1
    }
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory $Dir -Force | Out-Null }
    $cred | Export-Clixml -Path $Path -Force

    # Owner-only ACL, so another account on this PC cannot even read the ciphertext.
    try {
      $acl = Get-Acl $Path
      $acl.SetAccessRuleProtection($true, $false)
      $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
      $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'FullControl', 'Allow')))
      Set-Acl -Path $Path -AclObject $acl
    } catch { Write-Host "  (could not tighten file permissions: $($_.Exception.Message))" -ForegroundColor DarkYellow }

    Write-Host "  stored for user '$($cred.UserName)'." -ForegroundColor Green
    Write-Host '  The refresh will now sign itself back in when the session expires.'
    Write-Host ''
  }

  'Status' {
    $c = Read-Cred
    if ($c) {
      Write-Host "  stored     : yes" -ForegroundColor Green
      Write-Host "  user       : $($c.UserName)"
      Write-Host "  location   : $Path"
      Write-Host "  updated    : $((Get-Item $Path).LastWriteTime)"
      Write-Host "  (the password itself is not displayable)"
    } else {
      Write-Host "  stored     : no" -ForegroundColor Yellow
      Write-Host "  run:  .\scripts\optimo_credential.ps1 -Set"
    }
  }

  'Remove' {
    if (Test-Path $Path) { Remove-Item $Path -Force; Write-Host '  removed.' -ForegroundColor Green }
    else { Write-Host '  nothing stored.' -ForegroundColor Yellow }
  }

  'Emit' {
    # Machine-readable, for auto_export.mjs only. Goes down a stdout pipe to the
    # parent process - never onto a command line, where it would show up in the
    # process list for every user on the machine.
    $c = Read-Cred
    if (-not $c) { Write-Output '{"ok":false}'; exit 0 }
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
               [Runtime.InteropServices.Marshal]::SecureStringToBSTR($c.Password))
    Write-Output (@{ ok = $true; user = $c.UserName; pass = $plain } | ConvertTo-Json -Compress)
  }
}
