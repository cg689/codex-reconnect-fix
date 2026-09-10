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
    Exit code: 0 = fixed (or dry-run completed)
               1 = CodexHome / config.toml missing
               3 = write failed
               4 = refused by the proxy safety gate (nothing was written)
    Author: cg689  |  https://github.com/cg689/codex-reconnect-fix
#>

[CmdletBinding()]
param(
    [int]$Port = 0,
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$SetEnvironmentVariables,
    [switch]$SkipSystemProxy,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$SkipProxyCheck,
    [int]$ProxyTestTimeoutSec = 10
)

$ErrorActionPreference = 'Stop'

$RegPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ConfigPath  = Join-Path $CodexHome 'config.toml'
$BackupRoot  = Join-Path $CodexHome 'reconnect-fix-backups'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

$script:Changes = New-Object System.Collections.Generic.List[string]

# caches for the proxy-port discovery (see Get-CandidateClientDirs and friends)
$script:ClientDirsProbed  = $false
$script:ClientDirs        = @()
$script:ConfigPortsProbed = $false
$script:ConfigPorts       = @()
$script:ListeningProbed   = $false
$script:ListeningPorts    = @()

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
# proxy port resolution
#
# Evidence is collected from several sources, then the first entry that is
# actually LISTENING wins - a port nothing is listening on can only make
# matters worse, so a dead candidate is never preferred over a live one:
#
#   1. -Port
#   2. the port already written in the Windows system proxy setting
#   3. the inbound port found in an installed proxy client's config file
#      (v2rayN / Clash / mihomo / sing-box / Xray layouts)
#   4. any well-known proxy port that is currently listening
#   5. a dead candidate, so that the user is told which port was guessed
#   6. 10808
# ---------------------------------------------------------------------------

$script:CommonProxyPorts = @(
    7890,   # Clash / Clash for Windows / old Clash Verge
    7897,   # Clash Verge Rev / mihomo
    7891,   # secondary mixed port in some Clash setups
    10808,  # v2rayN
    10809,  # v2rayN / Xray
    1080,   # generic SOCKS/HTTP
    2080,   # sing-box default mixed port
    2081,   # sing-box secondary
    8889,   # common in CN client packs
    20171,  # common in CN client packs
    33210,  # common in CN client packs
    8118    # Privoxy
)

function Test-TcpPort {
    param([int]$TargetPort, [int]$TimeoutMs = 600)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ProxyChain {
    <#
        Does 127.0.0.1:<Port> actually behave as an HTTP proxy that can reach
        chatgpt.com? Any HTTP response counts as success - a 401/403 just means the
        tunnel was built. Only a transport failure (or a timeout) is a failure.
    #>
    param([int]$ProxyPort, [int]$Timeout)
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $true
    $handler.Proxy = New-Object System.Net.WebProxy(("http://127.0.0.1:{0}" -f $ProxyPort), $true)
    $handler.AllowAutoRedirect = $false

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.TimeSpan]::FromSeconds($Timeout)

    $req = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList @(
        [System.Net.Http.HttpMethod]::Get, 'https://chatgpt.com/')
    try {
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        return [pscustomobject]@{ Ok = $true; Detail = ('HTTP {0}' -f [int]$resp.StatusCode) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    } finally {
        if ($client)  { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
}

function Get-CandidateClientDirs {
    <#
        Directories of proxy clients that might be installed. Deliberately generic -
        no machine-specific paths. Cached - several helpers need the same list, and
        enumerating scheduled tasks / uninstall keys is not free.
    #>
    if ($script:ClientDirsProbed) { return $script:ClientDirs }

    $dirs = New-Object System.Collections.Generic.List[string]

    foreach ($name in @('v2rayN', 'clash', 'clash-verge', 'clash-verge-rev', 'verge-mihomo', 'mihomo', 'sing-box', 'Xray', 'nekobox')) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue |
                Where-Object { $_.Path } | Select-Object -First 1
        if ($proc) { $dirs.Add((Split-Path $proc.Path -Parent)) }
    }

    # uninstall registry entries (replaces any hard-coded install path)
    foreach ($root in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        foreach ($item in (Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
            if ($item.DisplayName -and $item.DisplayName -match 'v2ray|clash|sing-box|mihomo|Xray|nekoray|nekobox') {
                if ($item.InstallLocation -and (Test-Path $item.InstallLocation)) { $dirs.Add($item.InstallLocation) }
            }
        }
    }

    foreach ($guess in @(
        "$env:ProgramFiles\v2rayN",
        "${env:ProgramFiles(x86)}\v2rayN",
        "$env:LOCALAPPDATA\Programs\v2rayN",
        "$env:LOCALAPPDATA\Programs\clash-verge",
        "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
    )) {
        if (Test-Path $guess) { $dirs.Add($guess) }
    }

    if ($dirs.Count -eq 0 -and (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        # Last resort, and only when nothing cheaper found anything: reading the
        # scheduled-task store costs about two seconds on a typical machine.
        foreach ($task in (Get-ScheduledTask -TaskName 'v2rayNAutoRun_*' -ErrorAction SilentlyContinue)) {
            if ($task.Actions.Count -gt 0) {
                $exe = $task.Actions[0].Execute.Trim('"')
                if ($exe -and (Test-Path $exe)) { $dirs.Add((Split-Path $exe -Parent)) }
            }
        }
    }

    $script:ClientDirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)
    $script:ClientDirsProbed = $true
    return $script:ClientDirs
}

function Get-ConfigFilePorts {
    <#
        Inbound ports advertised by locally installed proxy clients. Heuristic on
        purpose: patterns are matched by regex so JSON and YAML layouts both work.
        Cached - the caller may resolve the port more than once per run.
    #>
    if ($script:ConfigPortsProbed) { return $script:ConfigPorts }

    $hits  = New-Object System.Collections.Generic.List[object]
    $files = New-Object System.Collections.Generic.List[string]

    foreach ($dir in (Get-CandidateClientDirs)) {
        foreach ($rel in @('guiConfigs\guiNConfig.json', 'binConfigs\config.json', 'config.json', 'config.yaml')) {
            $p = Join-Path $dir $rel
            if (Test-Path $p) { $files.Add($p) }
        }
    }

    foreach ($root in @(
        "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev",
        "$env:APPDATA\clash-verge",
        "$env:APPDATA\sing-box",
        "$env:USERPROFILE\.config\clash",
        "$env:USERPROFILE\.config\mihomo",
        "$env:USERPROFILE\.config\sing-box"
    )) {
        if (Test-Path $root) {
            # note: a plain foreach - List[string].AddRange() rejects an Object[] in PS 5.1
            $found = Get-ChildItem -Path $root -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in @('.json', '.yaml', '.yml') } |
                     Select-Object -First 20
            foreach ($f in $found) { $files.Add($f.FullName) }
        }
    }

    # YAML: only top-level (column 0) keys count. Subscriptions and generated configs
    # carry a `port:` inside every proxy node, and those are not inbound ports.
    # JSON: v2rayN / sing-box nest the inbound port, so indentation is allowed there.
    $yamlPattern = '(?im)^["'']?(mixed-port|mixed_port|listen_port|listen-port|http_port|http-port|socks-port|socks_port|localPort|port)["'']?\s*:\s*["'']?(\d{2,5})'
    $jsonPattern = '(?im)^\s*["'']?(mixed_port|listen_port|http_port|socks_port|localPort|local_port|port)["'']?\s*[:=]\s*["'']?(\d{2,5})'

    foreach ($file in ($files | Select-Object -Unique)) {
        # skip schema / example / verification artefacts that Clash Verge drops next to
        # the real config - they are full of unrelated port numbers
        if ((Split-Path $file -Leaf) -match '(?i)check|example|template|sample|schema|readme') { continue }

        $text = $null
        try { $text = Get-Content -Path $file -Raw -Encoding UTF8 -ErrorAction Stop } catch { continue }
        if (-not $text) { continue }

        $pattern = if ($file -match '\.ya?ml$') { $yamlPattern } else { $jsonPattern }
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $port = [int]$m.Groups[2].Value
            if ($hits | Where-Object { $_.Port -eq $port }) { continue }
            $hits.Add([pscustomobject]@{
                Port   = $port
                Source = ('config file {0} ({1})' -f (Split-Path $file -Leaf), $m.Groups[1].Value)
            })
        }
        if ($hits.Count -ge 3) { break }
    }

    $script:ConfigPorts = $hits
    $script:ConfigPortsProbed = $true
    return $script:ConfigPorts
}

function Get-ListeningPorts {
    <#
        Which well-known proxy ports are listening right now.

        Reading the kernel's TCP listen table through .NET is a few milliseconds;
        probing ports one by one (a connect attempt each) costs ~0.4 s per port because
        a refused loopback connect still burns the full timeout on Windows. Probing is
        kept only as a fallback.
    #>
    if ($script:ListeningProbed) { return $script:ListeningPorts }

    $live = New-Object System.Collections.Generic.List[int]
    $fromTable = $false

    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $openPorts = @{}
        foreach ($ep in $listeners) { $openPorts[[int]$ep.Port] = $true }
        foreach ($p in $script:CommonProxyPorts) {
            if ($openPorts.ContainsKey($p)) { $live.Add($p) }
        }
        $fromTable = $true
    } catch {
        $fromTable = $false
    }

    if (-not $fromTable) {
        foreach ($p in $script:CommonProxyPorts) {
            if (Test-TcpPort -TargetPort $p -TimeoutMs 150) { $live.Add($p) }
        }
    }

    $script:ListeningPorts = $live
    $script:ListeningProbed = $true
    return $script:ListeningPorts
}

function Resolve-ProxyPort {
    param([string]$CurrentProxyServer)

    if ($Port -gt 0) {
        $live = Test-TcpPort -TargetPort $Port
        return [pscustomobject]@{
            Port       = $Port
            Source     = 'forced by -Port'
            Live       = $live
            Candidates = @([pscustomobject]@{ Port = $Port; Source = 'forced by -Port'; Live = $live })
        }
    }

    # collect: system proxy setting, client config files, live well-known ports
    $raw = New-Object System.Collections.Generic.List[object]

    if ($CurrentProxyServer -match ':(?<p>\d{2,5})\s*$') {
        $raw.Add([pscustomobject]@{ Port = [int]$Matches['p']; Source = 'from the Windows system proxy setting' })
    }
    foreach ($h in (Get-ConfigFilePorts)) {
        $raw.Add([pscustomobject]@{ Port = [int]$h.Port; Source = $h.Source })
    }
    $listening = @(Get-ListeningPorts)
    foreach ($p in $listening) {
        $raw.Add([pscustomobject]@{ Port = $p; Source = 'well-known proxy port, currently listening' })
    }
    if ($raw.Count -eq 0) {
        $raw.Add([pscustomobject]@{ Port = 10808; Source = 'default (nothing detected)' })
    }

    # deduplicate; shortlist membership comes from the listen table (cheap)
    $candidates = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($c in $raw) {
        $n = [int]$c.Port
        if ($seen.ContainsKey($n)) { continue }
        $seen[$n] = $true
        $candidates.Add([pscustomobject]@{
            Port = $n; Source = $c.Source; Live = [bool]($listening -contains $n) })
    }

    $picked = $candidates | Where-Object { $_.Live } | Select-Object -First 1
    if (-not $picked) { $picked = $candidates | Select-Object -First 1 }

    # one authoritative connect on the port we are about to write into the system proxy
    return [pscustomobject]@{
        Port       = [int]$picked.Port
        Source     = $picked.Source
        Live       = (Test-TcpPort -TargetPort ([int]$picked.Port))
        Candidates = $candidates
    }
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

if (-not $SkipSystemProxy) {
    # listening ports first, then the rest - and never more than 6 rows of noise
    $others = @($portInfo.Candidates | Where-Object { [int]$_.Port -ne $proxyPort })
    $shown  = @($others | Where-Object { $_.Live } | Select-Object -First 3) +
              @($others | Where-Object { -not $_.Live } | Select-Object -First 3)
    if ($shown.Count -gt 0) {
        Write-Host ''
        Write-Host 'Other local proxy ports seen on this machine'
        foreach ($c in $shown) {
            Write-Item ("{0,-6} {1}   [{2}]" -f $c.Port, $c.Source,
                        $(if ($c.Live) { 'listening' } else { 'closed' }))
        }
        if ($others.Count -gt $shown.Count) {
            Write-Item ("... {0} more (not listed)" -f ($others.Count - $shown.Count))
        }
        Write-Item 'pass -Port <n> to use one of these instead'
    }
}

# ---- safety gate ---------------------------------------------------------
# Pointing the Windows system proxy at a port that is dead - or that is alive but
# cannot reach the outside world - takes the whole machine offline. Never do that
# silently.
Write-Head 'Safety check  Is the target port usable?'

if ($SkipProxyCheck) {
    Write-Item 'skipped (-SkipProxyCheck) - no probe was performed'
} else {
    $portLive = [bool]$portInfo.Live
    if ($portLive) {
        Write-Item ("127.0.0.1:{0}  -> accepting TCP connections" -f $proxyPort)
    } else {
        Write-Item ("127.0.0.1:{0}  -> NOTHING IS LISTENING" -f $proxyPort)
    }

    $chain = $null
    if ($portLive) {
        $chain = Test-ProxyChain -ProxyPort $proxyPort -Timeout $ProxyTestTimeoutSec
        if ($chain.Ok) {
            Write-Item ("proxy chain         -> reachable through it ({0})" -f $chain.Detail)
        } else {
            Write-Item ("proxy chain         -> FAILED ({0})" -f $chain.Detail)
        }
    }

    $refused = $null
    if (-not $portLive) {
        $refused = ("Nothing is listening on 127.0.0.1:{0}. " -f $proxyPort)
        if (-not $SkipSystemProxy) {
            $refused += 'Pointing the Windows system proxy at a dead port would take this machine offline ' +
                        '(every HTTPS request would fail).'
        } else {
            $refused += 'The proxy would be dead for Codex as well.'
        }
        if ($portInfo.Source -like 'default*' -or $portInfo.Source -like 'well-known*') {
            $refused += ("  Port {0} was only a guess - pass -Port <your real proxy port>." -f $proxyPort)
        } else {
            $refused += '  Start your proxy client - or its local inbound port changed.'
        }
    } elseif (-not $SkipSystemProxy -and $chain -and -not $chain.Ok) {
        $refused = ("127.0.0.1:{0} is listening but traffic through it cannot reach chatgpt.com." -f $proxyPort) +
                   ' Writing it into the system proxy would break normal browsing too. Fix the proxy chain (node / ' +
                   'subscription / outbound) first.'
    }

    if ($refused -and -not $Force) {
        Write-Host ''
        Write-Host 'REFUSED - nothing has been written.' -ForegroundColor Red
        Write-Host ''
        Write-Host $refused
        Write-Host ''
        Write-Host 'Options'
        Write-Host '  * start your proxy client and run this again'
        Write-Host ('  * point at the right port            : .\Fix-CodexReconnect.ps1 -Port <n>')
        Write-Host ('  * leave the system proxy alone       : .\Fix-CodexReconnect.ps1 -SkipSystemProxy -SetEnvironmentVariables')
        Write-Host ('  * override the check anyway          : .\Fix-CodexReconnect.ps1 -Force')
        if ($DryRun) { Write-Host ' (dry run - the real run would stop here)' }
        exit 4
    }
    if ($refused -and $Force) {
        Write-Item 'WARNING: overriding the safety check (-Force)'
    }
}

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
