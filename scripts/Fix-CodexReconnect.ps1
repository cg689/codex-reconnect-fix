#Requires -Version 5.1
<#
.SYNOPSIS
    Fix the "Codex / ChatGPT desktop keeps reconnecting 1/5 .. 5/5" problem on Windows.

.DESCRIPTION
    Applies the two changes that actually matter, in the right order:

      1. Re-enable the Windows system proxy and point it at your local proxy port
         (only the registry values ProxyEnable / ProxyServer are touched).
      2. Add - or turn on - the official Codex feature switch
         [features] respect_system_proxy = true in <CodexHome>\config.toml.

    Before anything is written, both the original config.toml and the original system
    proxy values are backed up, so .\Rollback-CodexReconnect.ps1 can undo everything.

    This script deliberately does NOT replace your model_provider. The provider-swap hack
    that is popular in forum threads works for the CLI but has been observed to hang the
    desktop client on startup.

.PARAMETER Port
    Local proxy port. Default: auto-detected from the current system proxy setting, a
    running v2rayN installation, then 10808.

.PARAMETER CodexHome
    Codex home directory. Default: %USERPROFILE%\.codex

.PARAMETER SetEnvironmentVariables
    Additionally persist HTTP_PROXY / HTTPS_PROXY / NO_PROXY as *user* environment
    variables. Use this when you cannot enable the system proxy (e.g. a client that
    fights over it) - the backend honours environment variables by default.

.PARAMETER SkipSystemProxy
    Do not touch the Windows system proxy. Pair with -SetEnvironmentVariables, or use it
    when your proxy client manages the system proxy itself.

.PARAMETER DryRun
    Print exactly what would change, write nothing.

.EXAMPLE
    .\Fix-CodexReconnect.ps1 -DryRun
    .\Fix-CodexReconnect.ps1
    .\Fix-CodexReconnect.ps1 -SetEnvironmentVariables -Port 10808

.NOTES
    Windows PowerShell 5.1 and PowerShell 7+. No admin rights required.
    Exit code: 0 = fixed (or dry-run completed), 1 = CodexHome / config.toml missing, 3 = write failed.
    Author: cg689  |  https://github.com/cg689/codex-reconnect-fix
#>

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$SetEnvironmentVariables,
    [switch]$SkipSystemProxy,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$RegPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ConfigPath  = Join-Path $CodexHome 'config.toml'
$BackupRoot  = Join-Path $CodexHome 'reconnect-fix-backups'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

$script:Changes = New-Object System.Collections.Generic.List[string]

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text
}

function Write-Item {
    param([string]$Text)
    Write-Host ('    {0}' -f $Text)
}

# ---------------------------------------------------------------------------
# port detection (same source order as the sibling v2rayn-proxy-guard project)
# ---------------------------------------------------------------------------

function Find-V2rayNDir {
    $proc = Get-Process v2rayN -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return Split-Path $proc.Path -Parent }

    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { $_.TaskName -like 'v2rayNAutoRun_*' } | Select-Object -First 1
        if ($task -and $task.Actions.Count -gt 0) {
            $exe = $task.Actions[0].Execute.Trim('"')
            if (Test-Path $exe) { return Split-Path $exe -Parent }
        }
    }

    foreach ($dir in @(
        "$env:ProgramFiles\v2rayN",
        "${env:ProgramFiles(x86)}\v2rayN",
        "$env:LOCALAPPDATA\Programs\v2rayN",
        "$env:USERPROFILE\Desktop\v2rayN",
        "D:\Software\v2rayN-windows-64-desktop\v2rayN-windows-64",
        "D:\v2rayN", "C:\v2rayN"
    )) {
        if (Test-Path (Join-Path $dir 'v2rayN.exe')) { return $dir }
    }
    return $null
}

function Resolve-ProxyPort {
    param([string]$CurrentProxyServer)
    if ($Port -gt 0) { return @{ Port = $Port; Source = 'forced by -Port' } }

    if ($CurrentProxyServer -match ':(?<p>\d{2,5})\s*$') {
        return @{ Port = [int]$Matches['p']; Source = 'from the current system proxy setting' }
    }

    $dir = Find-V2rayNDir
    if ($dir) {
        $guiFile = Join-Path $dir 'guiConfigs\guiNConfig.json'
        if (Test-Path $guiFile) {
            try {
                $gui = Get-Content $guiFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($gui.Inbound -and $gui.Inbound.Count -gt 0) {
                    return @{ Port = [int]$gui.Inbound[0].LocalPort; Source = "from v2rayN at $dir" }
                }
            } catch { }
        }
        $coreFile = Join-Path $dir 'binConfigs\config.json'
        if (Test-Path $coreFile) {
            try {
                $core = Get-Content $coreFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($in in $core.inbounds) {
                    $type = if ($in.type) { $in.type } else { $in.protocol }
                    if ($type -in @('mixed', 'socks', 'http')) {
                        if ($in.listen_port) { return @{ Port = [int]$in.listen_port; Source = "from core config at $dir" } }
                        if ($in.port)        { return @{ Port = [int]$in.port;        Source = "from core config at $dir" } }
                    }
                }
            } catch { }
        }
    }
    return @{ Port = 10808; Source = 'default (nothing detected)' }
}

# ---------------------------------------------------------------------------
# config.toml : set [features] respect_system_proxy = true
# ---------------------------------------------------------------------------

function Set-RespectSystemProxyFeature {
    <#
        Line-oriented, dependency-free TOML edit. Only the single key is touched;
        every other line, comment and blank line is preserved byte-for-byte.
        The file is rewritten as UTF-8 without BOM (a BOM breaks Codex's TOML parser)
        and keeps whichever line ending the file already used.
    #>
    param([string]$Path)

    $raw   = [System.IO.File]::ReadAllText($Path)
    $eol   = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($raw -split "\r?\n")) { $lines.Add($l) }

    # drop the single trailing element produced by a final newline
    $hadTrailingNewline = $raw -match "(\r?\n)$"
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $featureIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '[features]') { $featureIdx = $i; break }
    }

    $result = ''

    if ($featureIdx -lt 0) {
        $lines.Add('')
        $lines.Add('[features]')
        $lines.Add('respect_system_proxy = true')
        $result = 'appended a new [features] table with respect_system_proxy = true'
    } else {
        $end = $lines.Count
        for ($i = $featureIdx + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim().StartsWith('[')) { $end = $i; break }
        }

        $keyIdx = -1
        for ($i = $featureIdx + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match '^\s*respect_system_proxy\s*=') { $keyIdx = $i; break }
        }

        if ($keyIdx -ge 0) {
            if ($lines[$keyIdx].Trim() -eq 'respect_system_proxy = true') {
                return 'already set to true - nothing to change'
            }
            $lines[$keyIdx] = 'respect_system_proxy = true'
            $result = 'updated the existing respect_system_proxy key to true'
        } else {
            $lines.Insert($featureIdx + 1, 'respect_system_proxy = true')
            $result = 'inserted respect_system_proxy = true into the existing [features] table'
        }
    }

    $text = ($lines -join $eol)
    if ($hadTrailingNewline) { $text += $eol }
    [System.IO.File]::WriteAllText($Path, $text, $Utf8NoBom)
    return $result
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

Write-Host '============================================================='
Write-Host ' Codex Reconnect Fix'
if ($DryRun) { Write-Host ' MODE: dry run - nothing will be written' }
Write-Host '============================================================='

if (-not (Test-Path $CodexHome)) {
    Write-Host ''
    Write-Host ("ERROR: Codex home not found: {0}" -f $CodexHome) -ForegroundColor Red
    Write-Host 'Pass -CodexHome <path> if Codex stores its data somewhere else.'
    exit 1
}
if (-not (Test-Path $ConfigPath)) {
    Write-Host ''
    Write-Host ("ERROR: config.toml not found: {0}" -f $ConfigPath) -ForegroundColor Red
    Write-Host 'Start Codex once so it creates its configuration, then run this again.'
    exit 1
}

# ---- read the current state ----------------------------------------------
$props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
$currentEnable = if ($props) { [int]$props.ProxyEnable } else { 0 }
$currentServer = if ($props) { [string]$props.ProxyServer } else { '' }

$portInfo  = Resolve-ProxyPort -CurrentProxyServer $currentServer
$proxyPort = [int]$portInfo.Port
$target    = "127.0.0.1:$proxyPort"

Write-Host ''
Write-Host 'Current state'
Write-Item ("Codex home         : {0}" -f $CodexHome)
Write-Item ("Proxy port         : {0}  ({1})" -f $proxyPort, $portInfo.Source)
Write-Item ("System proxy       : enable={0} server='{1}'" -f $currentEnable, $currentServer)
Write-Item ("Target system proxy: {0}" -f $target)

# ---- backups -------------------------------------------------------------
$backupDir = $null
if (-not $DryRun) {
    $backupDir = Join-Path $BackupRoot $Stamp
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
}

Write-Head 'Step 1/3  Back up the current state'
if ($DryRun) {
    Write-Item ("would copy {0} -> {1}" -f $ConfigPath, (Join-Path $BackupRoot "$Stamp\config.toml"))
    Write-Item ("would record system proxy enable={0} server='{1}'" -f $currentEnable, $currentServer)
} else {
    Copy-Item -Path $ConfigPath -Destination (Join-Path $backupDir 'config.toml') -Force
    $state = [pscustomobject]@{
        createdAt       = (Get-Date -Format 'o')
        codexHome       = $CodexHome
        proxyEnable     = $currentEnable
        proxyServer     = $currentServer
        proxyPortUsed   = $proxyPort
        envVarsSet      = [bool]$SetEnvironmentVariables
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $backupDir 'state.json'),
        ($state | ConvertTo-Json -Depth 3),
        $Utf8NoBom)
    Write-Item ("config.toml  -> {0}" -f (Join-Path $backupDir 'config.toml'))
    Write-Item ("state.json   -> {0}" -f (Join-Path $backupDir 'state.json'))
    $script:Changes.Add("backup created at $backupDir")
}

# ---- step 2: system proxy ------------------------------------------------
Write-Head 'Step 2/3  Restore the Windows system proxy'
if ($SkipSystemProxy) {
    Write-Item 'skipped (-SkipSystemProxy)'
} elseif ($currentEnable -eq 1 -and $currentServer.Trim() -eq $target) {
    Write-Item ("already correct: enable=1 server='{0}'" -f $target)
} else {
    if ($DryRun) {
        Write-Item ("would set ProxyEnable=1  ProxyServer='{0}'  (was enable={1} server='{2}')" -f $target, $currentEnable, $currentServer)
    } else {
        try {
            Set-ItemProperty -Path $RegPath -Name ProxyEnable -Value 1      -Type DWord  -ErrorAction Stop
            Set-ItemProperty -Path $RegPath -Name ProxyServer -Value $target -Type String -ErrorAction Stop
            $check = Get-ItemProperty -Path $RegPath
            if ([int]$check.ProxyEnable -eq 1 -and [string]$check.ProxyServer -eq $target) {
                Write-Item ("FIXED: enable={0} server='{1}'  ->  enable=1 server='{2}'" -f $currentEnable, $currentServer, $target)
                $script:Changes.Add("system proxy restored to $target (was enable=$currentEnable server='$currentServer')")
            } else {
                Write-Item 'ERROR: the registry did not keep the new values'
                exit 3
            }
        } catch {
            Write-Host ('   ERROR: registry write failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
            exit 3
        }
    }
}

# ---- step 3: config.toml -------------------------------------------------
Write-Head 'Step 3/3  Enable [features] respect_system_proxy in config.toml'
if ($DryRun) {
    $raw = [System.IO.File]::ReadAllText($ConfigPath)
    if ($raw -match '(?m)^\s*respect_system_proxy\s*=\s*true\s*$') {
        Write-Item 'already set to true - nothing to change'
    } else {
        Write-Item 'would set respect_system_proxy = true under [features]'
    }
} else {
    try {
        $description = Set-RespectSystemProxyFeature -Path $ConfigPath
        Write-Item $description
        if ($description -notlike 'already*') {
            $script:Changes.Add("config.toml: $description")
        }
    } catch {
        Write-Host ('   ERROR: could not edit config.toml: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 3
    }
}

# ---- optional: user environment variables --------------------------------
if ($SetEnvironmentVariables) {
    Write-Head 'Extra  Persist proxy environment variables for the current user'
    foreach ($pair in @(
        @{ Name = 'HTTP_PROXY';  Value = "http://127.0.0.1:$proxyPort" },
        @{ Name = 'HTTPS_PROXY'; Value = "http://127.0.0.1:$proxyPort" },
        @{ Name = 'NO_PROXY';    Value = '127.0.0.1,localhost,::1' }
    )) {
        if ($DryRun) {
            Write-Item ("would set {0}={1}" -f $pair.Name, $pair.Value)
        } else {
            [System.Environment]::SetEnvironmentVariable($pair.Name, $pair.Value, 'User')
            Write-Item ("{0}={1}" -f $pair.Name, $pair.Value)
        }
    }
    if (-not $DryRun) {
        $script:Changes.Add('user environment variables HTTP_PROXY / HTTPS_PROXY / NO_PROXY set')
        Write-Item 'note: environment variables only reach apps launched after this change'
    }
}

# ---- summary -------------------------------------------------------------
Write-Host ''
Write-Host '-------------------------------------------------------------'
if ($DryRun) {
    Write-Host 'Dry run finished. Re-run without -DryRun to apply.'
} else {
    Write-Host 'Done. Summary of changes:'
    if ($script:Changes.Count -eq 0) {
        Write-Host '  (nothing needed changing - the configuration was already correct)'
    } else {
        foreach ($c in $script:Changes) { Write-Host ('  * {0}' -f $c) }
    }
    Write-Host ''
    Write-Host 'Next steps'
    Write-Host '  1. Fully quit the Codex / ChatGPT desktop app (check the tray icon) and start it again.'
    Write-Host '  2. Open a NEW conversation and send any message.'
    Write-Host '  3. It should answer immediately, with no "Reconnecting 1/5 .. 5/5" banner.'
    Write-Host ''
    Write-Host ('Verify with : .\Diagnose-CodexReconnect.ps1')
    if ($backupDir) {
        Write-Host ('Roll back   : .\Rollback-CodexReconnect.ps1 -Backup "{0}"' -f $backupDir)
    }
}
Write-Host '-------------------------------------------------------------'

exit 0
