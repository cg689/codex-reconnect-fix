#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose the "Codex / ChatGPT desktop keeps reconnecting 1/5 .. 5/5" problem on Windows.

.DESCRIPTION
    READ-ONLY. Modifies nothing. Safe to run at any time, including while Codex is running.

    The Codex Rust backend only reaches the network when one of these three layers
    provides a working route. All three are inspected:

      [1] Windows system proxy    HKCU\...\Internet Settings  (ProxyEnable / ProxyServer / PAC)
      [2] Proxy environment vars  HTTP_PROXY / HTTPS_PROXY / ALL_PROXY
      [3] Codex feature switch    <CodexHome>\config.toml -> [features] respect_system_proxy

    Then two live probes decide whether the route actually works:

      [4] TCP connect to the local proxy port
      [5] HTTPS request through the proxy, and a direct TCP connect for comparison

    The classic failure this script detects: layer [1] is on, but layer [3] is off and
    layer [2] is empty -> the backend ignores the system proxy, goes direct, gets blocked,
    and the UI retries five times before falling back.

.PARAMETER Port
    Proxy port to test. When omitted the port is auto-detected from, in order: the system
    proxy setting itself, a running v2rayN installation, then 10808.

.PARAMETER CodexHome
    Codex home directory. Default: %USERPROFILE%\.codex

.PARAMETER SkipNetworkTest
    Skip probes [4] and [5]. Use on a machine with no connectivity yet.

.PARAMETER TimeoutSec
    Per-probe network timeout in seconds. Default 12.

.PARAMETER ReportPath
    Also write the plain-text report to this file (useful when attaching to an issue).

.EXAMPLE
    .\Diagnose-CodexReconnect.ps1

.EXAMPLE
    .\Diagnose-CodexReconnect.ps1 -Port 10809 -ReportPath .\report.txt

.NOTES
    Windows PowerShell 5.1 and PowerShell 7+. No admin rights required.
    Exit code: 0 = healthy, 1 = problem found, 2 = CodexHome not found.
    Author: cg689  |  https://github.com/cg689/codex-reconnect-fix
#>

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$SkipNetworkTest,
    [int]$TimeoutSec = 12,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

$script:Report = New-Object System.Collections.Generic.List[string]
$script:Findings = New-Object System.Collections.Generic.List[object]

function Out-Line {
    param([string]$Text = '')
    $script:Report.Add($Text)
    Write-Host $Text
}

function Out-Row {
    param([string]$Label, [string]$Value, [string]$State = '')
    $tag = switch ($State) {
        'ok'   { 'OK  ' }
        'warn' { 'WARN' }
        'fail' { 'FAIL' }
        default { '    ' }
    }
    Out-Line ('    {0} {1,-22}: {2}' -f $tag, $Label, $Value)
}

function Add-Finding {
    param([string]$Severity, [string]$Text)
    $script:Findings.Add([pscustomobject]@{ Severity = $Severity; Text = $Text })
}

# ---------------------------------------------------------------------------
# probe [1] - Windows system proxy
# ---------------------------------------------------------------------------

function Get-SystemProxyState {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $p = Get-ItemProperty -Path $reg -ErrorAction Stop
    } catch {
        return [pscustomobject]@{
            Readable = $false; ProxyEnable = 0; ProxyServer = ''; AutoConfigURL = ''
        }
    }
    [pscustomobject]@{
        Readable      = $true
        ProxyEnable   = [int]$p.ProxyEnable
        ProxyServer   = [string]$p.ProxyServer
        AutoConfigURL = [string]$p.AutoConfigURL
    }
}

# ---------------------------------------------------------------------------
# probe [3] - parse config.toml without a TOML library
# ---------------------------------------------------------------------------

function Get-TomlScalar {
    <#
        Minimal TOML reader: returns the value of <Key> inside table [<Table>].
        Handles the flat `key = value` form only, which is all Codex needs here.
        Returns $null when the table or the key is absent.
    #>
    param([string]$Text, [string]$Table, [string]$Key)

    $lines = $Text -split "\r?\n"
    $inTable = $false
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        if ($line.StartsWith('[')) {
            $inTable = ($line -eq "[$Table]")
            continue
        }
        if (-not $inTable) { continue }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        if ($line.Substring(0, $eq).Trim() -ne $Key) { continue }

        $value = $line.Substring($eq + 1).Trim()
        # strip a trailing inline comment that is outside quotes
        if (-not $value.StartsWith('"') -and -not $value.StartsWith("'")) {
            $hash = $value.IndexOf('#')
            if ($hash -ge 0) { $value = $value.Substring(0, $hash).Trim() }
        }
        return $value.Trim('"').Trim("'")
    }
    return $null
}

function Test-Truthy {
    param([string]$Value)
    if ($null -eq $Value) { return $false }
    return ($Value.Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on'))
}

# ---------------------------------------------------------------------------
# probe [4] - TCP reachability
# ---------------------------------------------------------------------------

function Test-TcpPort {
    param([string]$TargetHost, [int]$TargetPort, [int]$TimeoutMs = 4000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# probe [5] - HTTPS through the proxy
# ---------------------------------------------------------------------------

function Test-ProxiedRequest {
    param([string]$Url, [string]$ProxyUrl, [int]$Timeout)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $true
    $handler.Proxy = New-Object System.Net.WebProxy($ProxyUrl, $true)
    $handler.AllowAutoRedirect = $false
    $handler.UseDefaultCredentials = $false

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds($Timeout)
    $client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', 'codex-reconnect-fix/diagnose') | Out-Null

    $req = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList @([System.Net.Http.HttpMethod]::Get, $Url)
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        return [pscustomobject]@{
            Ok     = $true
            Status = [int]$resp.StatusCode
            Detail = ('HTTP {0} {1} (tunnel OK)' -f [int]$resp.StatusCode, $resp.StatusCode)
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 0; Detail = $_.Exception.Message }
    } finally {
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

# ---------------------------------------------------------------------------
# port auto-detection (shared logic with the sibling v2rayn-proxy-guard project)
# ---------------------------------------------------------------------------

function Find-V2rayNDir {
    $proc = Get-Process v2rayN -ErrorAction SilentlyContinue |
            Where-Object { $_.Path } | Select-Object -First 1
    if ($proc) { return Split-Path $proc.Path -Parent }

    $task = $null
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -ErrorAction SilentlyContinue |
                Where-Object { $_.TaskName -like 'v2rayNAutoRun_*' } | Select-Object -First 1
    }
    if ($task -and $task.Actions.Count -gt 0) {
        $exe = $task.Actions[0].Execute.Trim('"')
        if (Test-Path $exe) { return Split-Path $exe -Parent }
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

function Get-DetectedPort {
    param([string]$SystemProxyServer)
    if ($SystemProxyServer -match ':(?<p>\d{2,5})\s*$') { return [int]$Matches['p'] }

    $dir = Find-V2rayNDir
    if ($dir) {
        $guiFile = Join-Path $dir 'guiConfigs\guiNConfig.json'
        if (Test-Path $guiFile) {
            try {
                $gui = Get-Content $guiFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($gui.Inbound -and $gui.Inbound.Count -gt 0) { return [int]$gui.Inbound[0].LocalPort }
            } catch { }
        }
        $coreFile = Join-Path $dir 'binConfigs\config.json'
        if (Test-Path $coreFile) {
            try {
                $core = Get-Content $coreFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($in in $core.inbounds) {
                    $type = if ($in.type) { $in.type } else { $in.protocol }
                    if ($type -in @('mixed', 'socks', 'http')) {
                        if ($in.listen_port) { return [int]$in.listen_port }
                        if ($in.port) { return [int]$in.port }
                    }
                }
            } catch { }
        }
    }
    return 10808
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

Out-Line '============================================================='
Out-Line ' Codex Reconnect Diagnose'
Out-Line ' "why does it keep saying: Reconnecting 1/5 .. 5/5 ?"'
Out-Line '============================================================='
Out-Line ''

# ---- [0] environment ------------------------------------------------------
$configPath = Join-Path $CodexHome 'config.toml'
$proxyState = Get-SystemProxyState

if ($Port -gt 0) {
    $portValue = $Port
    $portSource = 'forced by -Port'
} else {
    $portValue = Get-DetectedPort -SystemProxyServer $proxyState.ProxyServer
    $portSource = 'auto-detected'
}

Out-Line 'Context'
Out-Line ('    OS                : {0}' -f ([System.Environment]::OSVersion.VersionString))
Out-Line ('    PowerShell        : {0}' -f $PSVersionTable.PSVersion.ToString())
Out-Line ('    Codex home        : {0}' -f $CodexHome)
Out-Line ('    Proxy endpoint    : 127.0.0.1:{0}  ({1})' -f $portValue, $portSource)
Out-Line ''

$envProxyOk = $false
$featureOk  = $false
$systemOk   = $false

# ---- [1] Windows system proxy --------------------------------------------
Out-Line '[1] Windows system proxy  (HKCU\...\Internet Settings)'
if (-not $proxyState.Readable) {
    Out-Row -Label 'Registry' -Value 'could not be read' -State 'warn'
} else {
    $expected = "127.0.0.1:$portValue"
    $systemOk = ($proxyState.ProxyEnable -eq 1 -and $proxyState.ProxyServer.Trim() -eq $expected)

    if ($proxyState.ProxyEnable -eq 1) {
        Out-Row -Label 'ProxyEnable' -Value '1 (on)' -State 'ok'
    } else {
        Out-Row -Label 'ProxyEnable' -Value '0 (system proxy is OFF)' -State 'fail'
        Add-Finding 'fail' ('The Windows system proxy is disabled. Even with respect_system_proxy = true, ' +
                             'the Codex backend has nothing to respect. Enable the system proxy in your proxy client.')
    }

    if ($proxyState.ProxyServer -eq '') {
        Out-Row -Label 'ProxyServer' -Value '(empty)' -State $(if ($systemOk) { 'ok' } else { 'warn' })
    } elseif ($proxyState.ProxyServer.Trim() -eq $expected) {
        Out-Row -Label 'ProxyServer' -Value $proxyState.ProxyServer -State 'ok'
    } else {
        Out-Row -Label 'ProxyServer' -Value ("{0}   (expected {1})" -f $proxyState.ProxyServer, $expected) -State 'warn'
        $portHint = ("System proxy points at '{0}' but the detected proxy port is {1}. " -f $proxyState.ProxyServer, $portValue) +
                    'If that port belongs to another proxy client that is running, this is fine.'
        Add-Finding 'warn' $portHint
    }

    if ($proxyState.AutoConfigURL -ne '') {
        Out-Row -Label 'AutoConfigURL' -Value ("PAC in use: {0}" -f $proxyState.AutoConfigURL) -State 'warn'
        Add-Finding 'warn' 'A PAC script is configured. respect_system_proxy resolves PAC via WinHTTP, but the PAC must be reachable without a proxy, otherwise startup stalls.'
    } else {
        Out-Row -Label 'AutoConfigURL' -Value '(none)' -State 'ok'
    }
}
Out-Line ''

# ---- [2] proxy environment variables -------------------------------------
Out-Line '[2] Proxy environment variables'
$envNames = @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')
$envSet = @()
foreach ($name in $envNames) {
    $value = [System.Environment]::GetEnvironmentVariable($name)
    if ($value) {
        $envSet += $name
        Out-Row -Label $name -Value $value -State 'ok'
    } else {
        Out-Row -Label $name -Value '(not set)' -State ''
    }
}
$httpProxy = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY')
$httpsProxy = [System.Environment]::GetEnvironmentVariable('HTTPS_PROXY')
$envProxyOk = [bool]($httpProxy -or $httpsProxy)
Out-Line ''

# ---- [3] Codex feature switch --------------------------------------------
Out-Line '[3] Codex config switch  [features] respect_system_proxy'
if (-not (Test-Path $configPath)) {
    Out-Row -Label 'config.toml' -Value ("not found at {0}" -f $configPath) -State 'fail'
    Add-Finding 'fail' 'config.toml was not found - is Codex installed for this user?'
} else {
    Out-Row -Label 'config.toml' -Value $configPath -State 'ok'
    $raw = Get-Content -Path $configPath -Raw -Encoding UTF8
    $flagValue = Get-TomlScalar -Text $raw -Table 'features' -Key 'respect_system_proxy'
    $featureOk = Test-Truthy $flagValue

    if ($featureOk) {
        Out-Row -Label 'respect_system_proxy' -Value 'true' -State 'ok'
    } elseif ($null -eq $flagValue) {
        Out-Row -Label 'respect_system_proxy' -Value 'absent from [features]' -State 'fail'
        Add-Finding 'fail' 'respect_system_proxy is not set. The Codex backend will ignore the Windows system proxy and try to connect directly.'
    } else {
        Out-Row -Label 'respect_system_proxy' -Value ("{0} (not enabled)" -f $flagValue) -State 'fail'
        Add-Finding 'fail' 'respect_system_proxy is set but not true. The Codex backend will ignore the Windows system proxy.'
    }
}
Out-Line ''

# ---- [4] proxy port reachability -----------------------------------------
$portOpen = $null
if (-not $SkipNetworkTest) {
    Out-Line '[4] Proxy port reachability'
    $portOpen = Test-TcpPort -TargetHost '127.0.0.1' -TargetPort $portValue
    if ($portOpen) {
        Out-Row -Label ("127.0.0.1:{0}" -f $portValue) -Value 'accepting TCP connections' -State 'ok'
    } else {
        Out-Row -Label ("127.0.0.1:{0}" -f $portValue) -Value 'closed - nothing is listening' -State 'fail'
        Add-Finding 'fail' ("Nothing answers on 127.0.0.1:{0}. Start your proxy client (v2rayN / sing-box / ...) first - " -f $portValue) +
                            'without a live local proxy port nothing can be fixed by configuration alone.'
    }
    Out-Line ''
}

# ---- [5] end-to-end probes -----------------------------------------------
$proxyRequest = $null
if (-not $SkipNetworkTest) {
    Out-Line '[5] End-to-end probes'
    $proxyUrl = "http://127.0.0.1:$portValue"

    $proxyRequest = Test-ProxiedRequest -Url 'https://chatgpt.com/backend-api/me' -ProxyUrl $proxyUrl -Timeout $TimeoutSec
    if ($proxyRequest.Ok) {
        # any HTTP status proves the tunnel works; 401 is the normal answer without a session cookie
        Out-Row -Label 'via proxy (chatgpt.com)' -Value $proxyRequest.Detail -State 'ok'
    } else {
        Out-Row -Label 'via proxy (chatgpt.com)' -Value ('failed - ' + $proxyRequest.Detail) -State 'fail'
        $chainHint = ("The local proxy at 127.0.0.1:{0} cannot reach chatgpt.com. " -f $portValue) +
                     'The proxy chain itself is the problem (dead node / expired subscription / wrong outbound). Fix that first.'
        Add-Finding 'fail' $chainHint
    }

    $directOk = Test-TcpPort -TargetHost 'chatgpt.com' -TargetPort 443 -TimeoutMs 5000
    if ($directOk) {
        Out-Row -Label 'direct TCP 443' -Value 'reachable (a direct path also exists)' -State 'ok'
    } else {
        Out-Row -Label 'direct TCP 443' -Value 'blocked - a working proxy is mandatory here' -State 'warn'
    }
    Out-Line ''
}

# ---- verdict -------------------------------------------------------------
$rootCauseHit = (-not $featureOk) -and (-not $envProxyOk)

Out-Line '-------------------------------------------------------------'
if ($rootCauseHit) {
    Out-Line ' VERDICT: ROOT CAUSE FOUND'
    Out-Line '-------------------------------------------------------------'
    Out-Line ''
    Out-Line ' The Codex backend has no route to the internet:'
    Out-Line '   * [features] respect_system_proxy is not enabled in config.toml, and'
    Out-Line '   * no HTTP_PROXY / HTTPS_PROXY / ALL_PROXY environment variable is set.'
    Out-Line ''
    Out-Line ' The Rust backend (ReqwestDefault strategy) only honours proxy environment'
    Out-Line ' variables - it never reads the Windows system proxy. So requests go direct,'
    Out-Line ' get blocked, and the client retries 5 times before degrading to plain HTTP.'
    Out-Line ''
    Out-Line ' Fix: run .\Fix-CodexReconnect.ps1   then restart the Codex / ChatGPT desktop app.'
} elseif ($featureOk -and $systemOk -and ($portOpen -ne $false)) {
    Out-Line ' VERDICT: OK - configuration is consistent'
    Out-Line '-------------------------------------------------------------'
    Out-Line ''
    Out-Line ' The backend is allowed to use the system proxy and the proxy is alive.'
    Out-Line ' If you still see "Reconnecting 1/5", the proxy chain itself is likely at fault:'
    Out-Line '   * test another node / protocol inside your proxy client'
    Out-Line '   * check whether the subscription is expired'
    Out-Line '   * prefer a node that does not rely on QUIC/UDP if WebSocket fallback matters'
} else {
    Out-Line ' VERDICT: PROBLEM(S) FOUND - see the FAIL/WARN rows above'
    Out-Line '-------------------------------------------------------------'
}

if ($script:Findings.Count -gt 0) {
    Out-Line ''
    Out-Line 'What to do'
    $i = 1
    foreach ($f in $script:Findings) {
        Out-Line ('  {0}. [{1}] {2}' -f $i, $f.Severity.ToUpperInvariant(), $f.Text)
        $i++
    }
}
Out-Line ''

# ---- write the report ----------------------------------------------------
if ($ReportPath) {
    $full = [System.IO.Path]::GetFullPath($ReportPath)
    $dir = Split-Path $full -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($full, (($script:Report -join "`r`n") + "`r`n"), $utf8)
    Write-Host "Report written to: $full"
}

if (-not (Test-Path $CodexHome)) { exit 2 }
if ($script:Findings | Where-Object { $_.Severity -eq 'fail' }) { exit 1 }
exit 0
