#Requires -Version 5.1
<#
.SYNOPSIS
    Undo everything Fix-CodexReconnect.ps1 changed.

.DESCRIPTION
    Restores config.toml and the Windows system proxy from a backup folder created by
    Fix-CodexReconnect.ps1 (<CodexHome>\reconnect-fix-backups\<timestamp>\).
    When the backup recorded that user environment variables were set, they are removed
    again so the machine returns to its exact previous state.

.PARAMETER Backup
    Path of the backup folder. When omitted the most recent one is used.

.PARAMETER CodexHome
    Codex home directory. Default: %USERPROFILE%\.codex

.PARAMETER KeepSystemProxy
    Restore config.toml but leave the Windows system proxy as it is now.

.PARAMETER DryRun
    Print what would be restored, write nothing.

.EXAMPLE
    .\Rollback-CodexReconnect.ps1 -DryRun
    .\Rollback-CodexReconnect.ps1

.NOTES
    Windows PowerShell 5.1 and PowerShell 7+. No admin rights required.
    Exit code: 0 = restored, 1 = no backup found, 3 = restore failed.
    Author: cg689  |  https://github.com/cg689/codex-reconnect-fix
#>

[CmdletBinding()]
param(
    [string]$Backup,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$KeepSystemProxy,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RegPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$BackupRoot = Join-Path $CodexHome 'reconnect-fix-backups'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

function Write-Item {
    param([string]$Text)
    Write-Host ('    {0}' -f $Text)
}

Write-Host '============================================================='
Write-Host ' Codex Reconnect Fix - rollback'
if ($DryRun) { Write-Host ' MODE: dry run - nothing will be written' }
Write-Host '============================================================='
Write-Host ''

# ---- locate the backup ---------------------------------------------------
if (-not $Backup) {
    if (-not (Test-Path $BackupRoot)) {
        Write-Host ("ERROR: no backup folder found at {0}" -f $BackupRoot) -ForegroundColor Red
        Write-Host 'Run Fix-CodexReconnect.ps1 first, or pass -Backup <path>.'
        exit 1
    }
    $latest = Get-ChildItem -Path $BackupRoot -Directory |
              Sort-Object Name -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Host ("ERROR: {0} exists but contains no backup folders." -f $BackupRoot) -ForegroundColor Red
        exit 1
    }
    $Backup = $latest.FullName
}

if (-not (Test-Path $Backup)) {
    Write-Host ("ERROR: backup folder not found: {0}" -f $Backup) -ForegroundColor Red
    exit 1
}

$backupConfig = Join-Path $Backup 'config.toml'
$stateFile    = Join-Path $Backup 'state.json'

Write-Host ("Using backup: {0}" -f $Backup)
Write-Host ''

$state = $null
if (Test-Path $stateFile) {
    try { $state = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

# ---- restore config.toml -------------------------------------------------
Write-Host 'Step 1/2  Restore config.toml'
$targetConfig = Join-Path $CodexHome 'config.toml'
if (-not (Test-Path $backupConfig)) {
    Write-Item 'no config.toml in this backup - skipped'
} elseif ($DryRun) {
    Write-Item ("would copy {0} -> {1}" -f $backupConfig, $targetConfig)
} else {
    if (Test-Path $targetConfig) {
        Copy-Item -Path $targetConfig -Destination ($targetConfig + '.before-rollback') -Force
        Write-Item ("current file kept as {0}.before-rollback" -f (Split-Path $targetConfig -Leaf))
    }
    Copy-Item -Path $backupConfig -Destination $targetConfig -Force
    Write-Item 'restored'
}

# ---- restore the system proxy -------------------------------------------
Write-Host ''
Write-Host 'Step 2/2  Restore the Windows system proxy'
if ($KeepSystemProxy) {
    Write-Item 'skipped (-KeepSystemProxy)'
} elseif (-not $state) {
    Write-Item 'no state.json in this backup - the system proxy is left untouched'
} elseif ($DryRun) {
    Write-Item ("would set ProxyEnable={0} ProxyServer='{1}'" -f [int]$state.proxyEnable, [string]$state.proxyServer)
} else {
    try {
        Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value ([int]$state.proxyEnable) -Type DWord  -ErrorAction Stop
        Set-ItemProperty -Path $RegPath -Name ProxyServer -Value ([string]$state.proxyServer) -Type String -ErrorAction Stop
        Write-Item ("restored: ProxyEnable={0} ProxyServer='{1}'" -f [int]$state.proxyEnable, [string]$state.proxyServer)
    } catch {
        Write-Host ('    ERROR: registry write failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 3
    }
}

# ---- remove user environment variables ----------------------------------
if ($state -and $state.envVarsSet) {
    Write-Host ''
    Write-Host 'Extra  Remove the user environment variables that were added'
    foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')) {
        if ($DryRun) {
            Write-Item ("would clear {0}" -f $name)
        } else {
            [System.Environment]::SetEnvironmentVariable($name, $null, 'User')
            Write-Item ("cleared {0}" -f $name)
        }
    }
}

Write-Host ''
Write-Host '-------------------------------------------------------------'
if ($DryRun) {
    Write-Host 'Dry run finished. Re-run without -DryRun to restore.'
} else {
    Write-Host 'Rollback complete. Restart the Codex / ChatGPT desktop app.'
}
Write-Host '-------------------------------------------------------------'

exit 0
