#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Backup,
    [string]$CodexHome,
    [switch]$KeepSystemProxy,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexReconnect.Common.ps1')

try { $CodexHome = Resolve-CodexReconnectHome -RequestedHome $CodexHome } catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$RegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$BackupRoot = Join-Path $CodexHome 'reconnect-fix-backups'
$environmentNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')

function Write-Item { param([string]$Text) Write-Host ('    {0}' -f $Text) }

function Read-BackupState {
    param([string]$Path)
    $statePath = Join-Path $Path 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Resolve-BackupFolder {
    if ($Backup) {
        $resolved = [System.IO.Path]::GetFullPath($Backup)
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { throw "backup folder not found: $resolved" }
        return $resolved
    }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw "no backup folder found at $BackupRoot" }
    $selected = Find-LatestValidMutationBackup -Root $BackupRoot
    if ($selected) { return $selected }
    throw 'no valid mutation backup was found; empty, partial, and malformed folders were ignored'
}

function Restore-RegistryValue {
    param([string]$Name, $Entry, [string]$Type)
    if ([bool]$Entry.exists) { Set-ItemProperty -Path $RegPath -Name $Name -Value $Entry.value -Type $Type -ErrorAction Stop }
    else { Remove-ItemProperty -Path $RegPath -Name $Name -ErrorAction SilentlyContinue }
}

Write-Host '============================================================='
Write-Host ' Codex Reconnect Fix - rollback'
if ($DryRun) { Write-Host ' MODE: dry run - nothing will be written' }
Write-Host '============================================================='
Write-Host ''

try { $Backup = Resolve-BackupFolder } catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

$state = Read-BackupState -Path $Backup
$validation = Test-BackupState -State $state -BackupPath $Backup
if (-not $validation.Valid) {
    Write-Host ("ERROR: backup state is not safe to restore: {0}" -f $validation.Reason) -ForegroundColor Red
    exit 1
}

$backupConfig = Join-Path $Backup 'config.toml'
$targetConfig = Join-Path $CodexHome 'config.toml'
if (-not $validation.Legacy) {
    $recordedHome = [System.IO.Path]::GetFullPath([string]$state.codexHome)
    $recordedConfig = [System.IO.Path]::GetFullPath([string]$state.configPath)
    if ($recordedConfig -ne (Join-Path $recordedHome 'config.toml')) {
        Write-Host 'ERROR: backup configPath does not match its recorded Codex home.' -ForegroundColor Red
        exit 1
    }
    if ($recordedHome -ne [System.IO.Path]::GetFullPath($CodexHome)) {
        Write-Host ("ERROR: backup belongs to a different Codex home: {0}" -f $recordedHome) -ForegroundColor Red
        exit 1
    }
    $targetConfig = $recordedConfig
}
Write-Host ("Using backup: {0}" -f $Backup)
if ($validation.Legacy) { Write-Host 'WARNING: legacy backup; exact environment restoration is unavailable.' -ForegroundColor Yellow }

$mutations = if ($validation.Legacy) { @('config', 'systemProxy') } else { @($state.completedMutations) }
$restoreConfig = $mutations -contains 'config'
$restoreSystemProxy = (-not $KeepSystemProxy) -and ($mutations -contains 'systemProxy')
$restoreEnvironment = (-not $validation.Legacy) -and ($mutations -contains 'environment')

if ($restoreConfig -and -not (Test-Path -LiteralPath $backupConfig -PathType Leaf)) {
    Write-Host 'ERROR: config.toml backup is required but missing; nothing was restored.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Restore plan'
Write-Item $(if ($restoreConfig) { 'config.toml: exact prior bytes' } else { 'config.toml: not changed by this Fix; skipped' })
Write-Item $(if ($restoreSystemProxy) { 'Windows proxy: exact prior existence and values' } elseif ($KeepSystemProxy) { 'Windows proxy: skipped (-KeepSystemProxy)' } else { 'Windows proxy: not changed by this Fix; skipped' })
Write-Item $(if ($restoreEnvironment) { 'user environment: exact prior existence and values' } else { 'user environment: not changed by this Fix; skipped' })

if ($DryRun) {
    Write-Host ''
    Write-Host '-------------------------------------------------------------'
    Write-Host 'Dry run finished. No state was changed.'
    Write-Host '-------------------------------------------------------------'
    exit 0
}

$operations = New-Object System.Collections.Generic.List[object]
if ($restoreConfig) {
    $backupConfigBytes = [System.IO.File]::ReadAllBytes($backupConfig)
    $currentConfigExists = Test-Path -LiteralPath $targetConfig -PathType Leaf
    $currentConfigBytes = if ($currentConfigExists) { [System.IO.File]::ReadAllBytes($targetConfig) } else { $null }
    $operations.Add([pscustomobject]@{
        Name = 'config'
        Apply = { Write-AtomicBytes -Path $targetConfig -Bytes $backupConfigBytes }.GetNewClosure()
        Rollback = {
            if ($currentConfigExists) { Write-AtomicBytes -Path $targetConfig -Bytes $currentConfigBytes }
            else { Remove-Item -LiteralPath $targetConfig -Force -ErrorAction SilentlyContinue }
        }.GetNewClosure()
    })
}

if ($restoreSystemProxy) {
    $currentProps = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
    $currentRegistry = @{}
    foreach ($name in @('ProxyEnable', 'ProxyServer', 'AutoConfigURL', 'AutoDetect')) {
        $exists = [bool]($currentProps -and $currentProps.PSObject.Properties[$name])
        $currentRegistry[$name] = New-ExactValueState -Exists $exists -Value $(if ($exists) { $currentProps.$name } else { $null })
    }
    $operations.Add([pscustomobject]@{
        Name = 'systemProxy'
        Apply = {
            if ($validation.Legacy) {
                Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value ([int]$state.proxyEnable) -Type DWord -ErrorAction Stop
                Set-ItemProperty -Path $RegPath -Name ProxyServer -Value ([string]$state.proxyServer) -Type String -ErrorAction Stop
            } else {
                Restore-RegistryValue -Name 'ProxyEnable' -Entry $state.proxyEnable -Type DWord
                Restore-RegistryValue -Name 'ProxyServer' -Entry $state.proxyServer -Type String
                Restore-RegistryValue -Name 'AutoConfigURL' -Entry $state.autoConfigUrl -Type String
                Restore-RegistryValue -Name 'AutoDetect' -Entry $state.autoDetect -Type DWord
            }
        }.GetNewClosure()
        Rollback = {
            Restore-RegistryValue -Name 'ProxyEnable' -Entry $currentRegistry.ProxyEnable -Type DWord
            Restore-RegistryValue -Name 'ProxyServer' -Entry $currentRegistry.ProxyServer -Type String
            Restore-RegistryValue -Name 'AutoConfigURL' -Entry $currentRegistry.AutoConfigURL -Type String
            Restore-RegistryValue -Name 'AutoDetect' -Entry $currentRegistry.AutoDetect -Type DWord
        }.GetNewClosure()
    })
}

if ($restoreEnvironment) {
    $currentEnvironment = Get-UserEnvironmentSnapshot -Names $environmentNames
    $operations.Add([pscustomobject]@{
        Name = 'environment'
        Apply = { Restore-UserEnvironmentSnapshot -Snapshot $state.environment -Names $environmentNames }.GetNewClosure()
        Rollback = { Restore-UserEnvironmentSnapshot -Snapshot $currentEnvironment -Names $environmentNames }.GetNewClosure()
    })
}

$result = Invoke-RecoverableTransaction -Operations $operations -OnCompleted { param($name) Write-Item ("restored {0}" -f $name) }

Write-Host ''
Write-Host '-------------------------------------------------------------'
if (-not $result.Succeeded) {
    Write-Host ("Rollback failed: {0}" -f $result.Error.Exception.Message) -ForegroundColor Red
    if (@($result.Unrecovered).Count -eq 0) { Write-Host 'Earlier restore steps were compensated back to their pre-rollback state.' }
    else {
        Write-Host 'These compensated surfaces could not be returned to their pre-rollback state:' -ForegroundColor Red
        foreach ($failure in $result.Unrecovered) { Write-Host ('  * {0}' -f $failure) }
    }
    Write-Host '-------------------------------------------------------------'
    exit 3
}
Write-Host 'Rollback complete. Restart the Codex / ChatGPT desktop app.'
Write-Host '-------------------------------------------------------------'
exit 0
