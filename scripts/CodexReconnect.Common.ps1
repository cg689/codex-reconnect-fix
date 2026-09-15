#Requires -Version 5.1

$script:CodexReconnectUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-DefaultCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw 'Neither CODEX_HOME nor USERPROFILE is available.'
    }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Resolve-CodexReconnectHome {
    param([AllowNull()][string]$RequestedHome)
    if ([string]::IsNullOrWhiteSpace($RequestedHome)) { return (Get-DefaultCodexHome) }
    return [System.IO.Path]::GetFullPath([System.Environment]::ExpandEnvironmentVariables($RequestedHome))
}

function Assert-CodexReconnectParameters {
    param([int]$Port, [int]$TimeoutSec, [string]$TimeoutName = 'TimeoutSec')
    if ($Port -lt 0 -or $Port -gt 65535) { throw '-Port must be between 0 and 65535.' }
    if ($TimeoutSec -lt 1 -or $TimeoutSec -gt 300) { throw ("-{0} must be between 1 and 300 seconds." -f $TimeoutName) }
}

function Protect-SensitiveText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $null }

    $redacted = [regex]::Replace(
        $Text,
        '(?i)\b(?<scheme>https?|socks4a?|socks5h?)://(?<userinfo>[^\s/@]+(?::[^\s/@]*)?)@',
        '${scheme}://[REDACTED]@')
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<name>password|passwd|token|secret|api[_-]?key)=(?<value>[^\s;&]+)',
        '${name}=[REDACTED]')
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)(?<base>\b(?:https?|socks4a?|socks5h?)://[^\s?#]+)\?[^\s#]*',
        '${base}?[REDACTED]')
    return $redacted
}

function Get-CommentIndex {
    param([string]$Text)
    $quote = [char]0
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($escaped) { $escaped = $false; continue }
        if ($quote -eq '"' -and $character -eq '\') { $escaped = $true; continue }
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -eq '"' -or $character -eq "'") { $quote = $character; continue }
        if ($character -eq '#') { return $index }
    }
    if ($quote -ne [char]0) { throw 'Unterminated quoted string.' }
    return -1
}

function Split-TomlAssignment {
    param([string]$Text)
    $quote = [char]0
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($escaped) { $escaped = $false; continue }
        if ($quote -eq '"' -and $character -eq '\') { $escaped = $true; continue }
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -eq '"' -or $character -eq "'") { $quote = $character; continue }
        if ($character -eq '=') {
            return [pscustomobject]@{
                Key = $Text.Substring(0, $index).Trim()
                Value = $Text.Substring($index + 1).Trim()
            }
        }
    }
    if ($quote -ne [char]0) { throw 'Unterminated quoted key.' }
    return $null
}

function ConvertFrom-TomlKeyPart {
    param([string]$Text)
    $value = $Text.Trim()
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') -or
                                  ($value[0] -eq "'" -and $value[$value.Length - 1] -eq "'"))) {
        return $value.Substring(1, $value.Length - 2)
    }
    if ($value -notmatch '^[A-Za-z0-9_-]+$') { throw "Unsupported or ambiguous TOML key: $Text" }
    return $value
}

function Get-TomlLogicalKey {
    param([string]$Text)
    $parts = New-Object System.Collections.Generic.List[string]
    $start = 0
    $quote = [char]0
    $escaped = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        if ($escaped) { $escaped = $false; continue }
        if ($quote -eq '"' -and $character -eq '\') { $escaped = $true; continue }
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -eq '"' -or $character -eq "'") { $quote = $character; continue }
        if ($character -eq '.') {
            $parts.Add((ConvertFrom-TomlKeyPart $Text.Substring($start, $index - $start)))
            $start = $index + 1
        }
    }
    if ($quote -ne [char]0) { throw 'Unterminated quoted key.' }
    $parts.Add((ConvertFrom-TomlKeyPart $Text.Substring($start)))
    return ($parts -join '.')
}

function Get-RespectSystemProxyPlan {
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($Text.IndexOf([char]0) -ge 0) { throw 'config.toml contains a NUL byte.' }
    $eol = if ($Text -match "`r`n") { "`r`n" } else { "`n" }
    $hadTrailingNewline = $Text -match '(\r?\n)$'
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line) }
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    $featureHeaders = New-Object System.Collections.Generic.List[int]
    $logicalKeys = New-Object System.Collections.Generic.List[object]
    $currentTable = ''

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $raw = $lines[$index]
        $commentIndex = Get-CommentIndex $raw
        $code = if ($commentIndex -ge 0) { $raw.Substring(0, $commentIndex).Trim() } else { $raw.Trim() }
        if ($code -eq '') { continue }

        if ($code.StartsWith('[[')) {
            if (-not $code.EndsWith(']]')) { throw "Malformed TOML array table header near line $($index + 1)." }
            $currentTable = '__array_table__'
            continue
        }
        if ($code.StartsWith('[')) {
            if (-not $code.EndsWith(']')) { throw "Malformed TOML table header near line $($index + 1)." }
            $currentTable = Get-TomlLogicalKey $code.Substring(1, $code.Length - 2)
            if ($currentTable -eq 'features') { $featureHeaders.Add($index) }
            continue
        }

        $assignment = Split-TomlAssignment $code
        if (-not $assignment) { continue }
        $key = Get-TomlLogicalKey $assignment.Key
        $logical = if ($currentTable) { "$currentTable.$key" } else { $key }
        if ($logical -eq 'features.respect_system_proxy') {
            $logicalKeys.Add([pscustomobject]@{ Line = $index; KeyText = $assignment.Key; Table = $currentTable })
        }
    }

    if ($featureHeaders.Count -gt 1) { throw 'config.toml contains duplicate [features] tables.' }
    if ($logicalKeys.Count -gt 1) { throw 'config.toml contains duplicate logical respect_system_proxy keys.' }
    if ($featureHeaders.Count -eq 1 -and $logicalKeys.Count -eq 1 -and [string]::IsNullOrEmpty($logicalKeys[0].Table)) {
        throw 'config.toml mixes a dotted features key with an explicit [features] table.'
    }

    $description = ''
    if ($logicalKeys.Count -eq 1) {
        $lineIndex = $logicalKeys[0].Line
        $raw = $lines[$lineIndex]
        $commentIndex = Get-CommentIndex $raw
        $comment = if ($commentIndex -ge 0) { $raw.Substring($commentIndex) } else { '' }
        $code = if ($commentIndex -ge 0) { $raw.Substring(0, $commentIndex) } else { $raw }
        $assignment = Split-TomlAssignment $code
        $prefix = $code.Substring(0, $code.IndexOf('=') + 1)
        if ($assignment.Value.Trim() -notmatch '^(?i:true|false)$') {
            throw 'respect_system_proxy must be a TOML boolean before it can be changed safely.'
        }
        $replacement = $prefix + ' true'
        if ($comment) { $replacement += ' ' + $comment.TrimStart() }
        if ($raw -eq $replacement) {
            return [pscustomobject]@{ Changed = $false; Text = $Text; Description = 'already set to true' }
        }
        $lines[$lineIndex] = $replacement
        $description = 'updated the existing logical respect_system_proxy key'
    } elseif ($featureHeaders.Count -eq 1) {
        $lines.Insert($featureHeaders[0] + 1, 'respect_system_proxy = true')
        $description = 'inserted respect_system_proxy into the existing [features] table'
    } else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne '') { $lines.Add('') }
        $lines.Add('[features]')
        $lines.Add('respect_system_proxy = true')
        $description = 'appended a new [features] table'
    }

    $result = $lines -join $eol
    if ($hadTrailingNewline) { $result += $eol }
    return [pscustomobject]@{ Changed = $true; Text = $result; Description = $description }
}

function Get-RespectSystemProxyValue {
    param([Parameter(Mandatory = $true)][string]$Text)
    $plan = Get-RespectSystemProxyPlan -Text $Text
    if ($plan.Changed) {
        $hasExistingKey = $plan.Description -like 'updated*'
        if (-not $hasExistingKey) { return $null }
    }

    $lines = $Text -split '\r?\n'
    $currentTable = ''
    $values = @()
    foreach ($raw in $lines) {
        $commentIndex = Get-CommentIndex $raw
        $code = if ($commentIndex -ge 0) { $raw.Substring(0, $commentIndex).Trim() } else { $raw.Trim() }
        if (-not $code) { continue }
        if ($code.StartsWith('[')) {
            if ($code.StartsWith('[[')) {
                if (-not $code.EndsWith(']]')) { throw 'Malformed TOML array table header.' }
                $currentTable = '__array_table__'
                continue
            }
            if (-not $code.EndsWith(']')) { throw 'Malformed TOML table header.' }
            $currentTable = Get-TomlLogicalKey $code.Substring(1, $code.Length - 2)
            continue
        }
        $assignment = Split-TomlAssignment $code
        if (-not $assignment) { continue }
        $key = Get-TomlLogicalKey $assignment.Key
        $logical = if ($currentTable) { "$currentTable.$key" } else { $key }
        if ($logical -eq 'features.respect_system_proxy') { $values += $assignment.Value.Trim() }
    }
    if ($values.Count -eq 0) { return $null }
    if ($values.Count -gt 1) { throw 'Duplicate logical respect_system_proxy keys.' }
    return $values[0]
}

function Test-TomlTrue {
    param([AllowNull()][string]$Value)
    return ($null -ne $Value -and $Value.Trim().ToLowerInvariant() -eq 'true')
}

function Write-AtomicTextFile {
    param([string]$Path, [string]$Text)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path $fullPath -Parent
    $temporary = Join-Path $directory ('.codex-reconnect-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $script:CodexReconnectUtf8NoBom)
        if (Test-Path -LiteralPath $fullPath) {
            [System.IO.File]::Replace($temporary, $fullPath, $null)
        } else {
            [System.IO.File]::Move($temporary, $fullPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AtomicBytes {
    param([string]$Path, [byte[]]$Bytes)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path $fullPath -Parent
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = Join-Path $directory ('.codex-reconnect-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $fullPath) { [System.IO.File]::Replace($temporary, $fullPath, $null) }
        else { [System.IO.File]::Move($temporary, $fullPath) }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-RecoverableTransaction {
    param([object[]]$Operations, [scriptblock]$OnCompleted)
    $completed = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($operation in $Operations) {
            $completed.Add($operation)
            & $operation.Apply
            if ($OnCompleted) { & $OnCompleted $operation.Name }
        }
        return [pscustomobject]@{ Succeeded = $true; Unrecovered = @(); Error = $null }
    } catch {
        $originalError = $_
        $unrecovered = New-Object System.Collections.Generic.List[string]
        for ($index = $completed.Count - 1; $index -ge 0; $index--) {
            try { & $completed[$index].Rollback } catch { $unrecovered.Add([string]$completed[$index].Name) }
        }
        return [pscustomobject]@{ Succeeded = $false; Unrecovered = @($unrecovered); Error = $originalError }
    }
}

function Get-UserEnvironmentSnapshot {
    param([string[]]$Names)
    $result = [ordered]@{}
    foreach ($name in $Names) {
        $value = [System.Environment]::GetEnvironmentVariable($name, 'User')
        $result[$name] = [ordered]@{ Exists = ($null -ne $value); Value = $value }
    }
    return $result
}

function New-ExactValueState {
    param([bool]$Exists, [AllowNull()][object]$Value)
    return [pscustomobject]@{ exists = $Exists; value = $Value }
}

function Get-ReversedMutationList {
    param([object[]]$Mutations)
    $result = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Mutations) { return $result.ToArray() }
    for ($index = $Mutations.Count - 1; $index -ge 0; $index--) { $result.Add($Mutations[$index]) }
    return $result.ToArray()
}

function Restore-UserEnvironmentSnapshot {
    param($Snapshot, [string[]]$Names)
    foreach ($entry in (Get-EnvironmentRestorePlan -Snapshot $Snapshot -Names $Names)) {
        [System.Environment]::SetEnvironmentVariable($entry.Name, $entry.Value, 'User')
    }
}

function Get-EnvironmentRestorePlan {
    param($Snapshot, [string[]]$Names)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Names) {
        $entry = $Snapshot.$name
        if ($null -eq $entry) { throw "Backup is missing environment state for $name." }
        $result.Add([pscustomobject]@{
            Name = $name
            Exists = [bool]$entry.Exists
            Value = $(if ([bool]$entry.Exists) { [string]$entry.Value } else { $null })
        })
    }
    return $result.ToArray()
}

function Get-SimpleProxyEndpoint {
    param([AllowNull()][string]$ProxyServer)
    if ([string]::IsNullOrWhiteSpace($ProxyServer)) {
        return [pscustomobject]@{ Supported = $false; Complex = $false; Reason = 'empty'; Uri = $null; Host = $null; Port = 0 }
    }
    $value = $ProxyServer.Trim()
    if ($value.Contains(';') -or $value.Contains('=')) {
        return [pscustomobject]@{ Supported = $false; Complex = $true; Reason = 'per-protocol proxy mapping'; Uri = $null; Host = $null; Port = 0 }
    }
    $candidate = if ($value -match '^[A-Za-z][A-Za-z0-9+.-]*://') { $value } else { "http://$value" }
    $uri = $null
    if (-not [uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$uri) -or $uri.Port -le 0) {
        return [pscustomobject]@{ Supported = $false; Complex = $true; Reason = 'unrecognized proxy address'; Uri = $null; Host = $null; Port = 0 }
    }
    return [pscustomobject]@{ Supported = $true; Complex = $false; Reason = ''; Uri = $uri.AbsoluteUri; Host = $uri.Host; Port = $uri.Port; Scheme = $uri.Scheme.ToLowerInvariant() }
}

function Get-PerProtocolProxyEndpoint {
    param([AllowNull()][string]$ProxyServer)
    if ([string]::IsNullOrWhiteSpace($ProxyServer) -or -not $ProxyServer.Contains('=')) { return $null }
    $mapping = @{}
    foreach ($part in ($ProxyServer -split ';')) {
        $assignment = $part -split '=', 2
        if ($assignment.Count -ne 2) { continue }
        $mapping[$assignment[0].Trim().ToLowerInvariant()] = $assignment[1].Trim()
    }
    $selected = if ($mapping.ContainsKey('https')) { $mapping['https'] } elseif ($mapping.ContainsKey('http')) { $mapping['http'] } else { $null }
    if (-not $selected) { return $null }
    return (Get-SimpleProxyEndpoint -ProxyServer $selected)
}

function Get-EffectiveProxyRoute {
    param($Environment, [bool]$FeatureEnabled, [int]$ProxyEnable, [AllowNull()][string]$ProxyServer, [AllowNull()][string]$AutoConfigUrl, [int]$AutoDetect)
    foreach ($name in @('HTTPS_PROXY', 'ALL_PROXY', 'HTTP_PROXY')) {
        $value = [string]$Environment.$name
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $endpoint = Get-SimpleProxyEndpoint -ProxyServer $value
        $verifiable = $endpoint.Supported -and $endpoint.Scheme -in @('http', 'https')
        return [pscustomobject]@{ Kind = 'environment'; Source = $name; Configured = $true; Verifiable = $verifiable; ProxyUrl = $(if ($endpoint.Supported) { $endpoint.Uri } else { $value }); Host = $endpoint.Host; Port = $endpoint.Port; Reason = $(if ($verifiable) { '' } elseif ($endpoint.Supported) { "proxy scheme '$($endpoint.Scheme)' cannot be verified by this script" } else { $endpoint.Reason }) }
    }
    if (-not $FeatureEnabled) { return [pscustomobject]@{ Kind = 'none'; Source = ''; Configured = $false; Verifiable = $false; ProxyUrl = $null; Host = $null; Port = 0; Reason = 'no proxy environment variable is set and respect_system_proxy is not enabled' } }
    if (-not [string]::IsNullOrWhiteSpace($AutoConfigUrl) -or $AutoDetect -ne 0) { return [pscustomobject]@{ Kind = 'system-auto'; Source = 'Windows PAC/WPAD'; Configured = $true; Verifiable = $false; ProxyUrl = $null; Host = $null; Port = 0; Reason = 'PAC/WPAD routing cannot be proven by a single explicit proxy request' } }
    if ($ProxyEnable -ne 1) { return [pscustomobject]@{ Kind = 'none'; Source = 'Windows system proxy'; Configured = $false; Verifiable = $false; ProxyUrl = $null; Host = $null; Port = 0; Reason = 'Windows system proxy is disabled' } }
    $endpoint = if ($ProxyServer -match '=') { Get-PerProtocolProxyEndpoint -ProxyServer $ProxyServer } else { Get-SimpleProxyEndpoint -ProxyServer $ProxyServer }
    if ($null -eq $endpoint -or -not $endpoint.Supported) { return [pscustomobject]@{ Kind = 'system-complex'; Source = 'Windows system proxy'; Configured = $true; Verifiable = $false; ProxyUrl = $null; Host = $null; Port = 0; Reason = 'the system proxy topology is not safely reducible to one HTTPS proxy endpoint' } }
    $verifiable = $endpoint.Scheme -in @('http', 'https')
    return [pscustomobject]@{ Kind = $(if ($ProxyServer -match '=') { 'system-per-protocol' } else { 'system-simple' }); Source = 'Windows system proxy'; Configured = $true; Verifiable = $verifiable; ProxyUrl = $endpoint.Uri; Host = $endpoint.Host; Port = $endpoint.Port; Reason = $(if ($verifiable) { '' } else { "proxy scheme '$($endpoint.Scheme)' cannot be verified by this script" }) }
}

function Get-ProxyServerClassification {
    param([AllowNull()][string]$ProxyServer)
    $endpoint = Get-SimpleProxyEndpoint -ProxyServer $ProxyServer
    if ($endpoint.Supported -and $endpoint.Host -in @('127.0.0.1', 'localhost', '::1')) {
        return [pscustomobject]@{ Kind = 'simple-local'; Port = $endpoint.Port; SafeToReplace = $true }
    }
    if ([string]::IsNullOrWhiteSpace($ProxyServer)) {
        return [pscustomobject]@{ Kind = 'none'; Port = 0; SafeToReplace = $true }
    }
    return [pscustomobject]@{ Kind = $(if ($endpoint.Complex) { 'complex' } else { 'custom' }); Port = 0; SafeToReplace = $false }
}

function Get-DiagnoseVerdict {
    param([bool]$RouteConfigured, [bool]$RequiredProbeRan, [bool]$RequiredProbePassed, [bool]$HasFailure)
    if ($HasFailure) { return 'PROBLEM' }
    if (-not $RouteConfigured -or -not $RequiredProbeRan -or -not $RequiredProbePassed) { return 'UNVERIFIED' }
    return 'OK'
}

function Test-BackupState {
    param($State, [string]$BackupPath)
    if ($null -eq $State) { return [pscustomobject]@{ Valid = $false; Reason = 'state.json is missing or malformed'; Legacy = $false } }
    if ($State.schemaVersion -eq 2) {
        if ([string]::IsNullOrWhiteSpace([string]$State.mutationId)) { return [pscustomobject]@{ Valid = $false; Reason = 'mutationId is missing'; Legacy = $false } }
        if ([string]::IsNullOrWhiteSpace([string]$State.codexHome)) { return [pscustomobject]@{ Valid = $false; Reason = 'codexHome is missing'; Legacy = $false } }
        if ($null -eq $State.completedMutations) { return [pscustomobject]@{ Valid = $false; Reason = 'completedMutations is missing'; Legacy = $false } }
        if (-not [bool]$State.completed) { return [pscustomobject]@{ Valid = $false; Reason = 'backup transaction did not complete'; Legacy = $false } }
        foreach ($name in @('configPath', 'proxyEnable', 'proxyServer', 'autoConfigUrl', 'autoDetect', 'environment')) {
            if ($null -eq $State.$name) { return [pscustomobject]@{ Valid = $false; Reason = "$name is missing"; Legacy = $false } }
        }
        foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')) {
            if ($null -eq $State.environment.$name) { return [pscustomobject]@{ Valid = $false; Reason = "environment.$name is missing"; Legacy = $false } }
        }
        return [pscustomobject]@{ Valid = $true; Reason = ''; Legacy = $false }
    }
    if ($null -ne $State.proxyEnable -and $null -ne $State.proxyServer -and $State.codexHome) {
        if ($State.envVarsSet) { return [pscustomobject]@{ Valid = $false; Reason = 'legacy backup cannot restore previous environment values exactly'; Legacy = $true } }
        return [pscustomobject]@{ Valid = $true; Reason = ''; Legacy = $true }
    }
    return [pscustomobject]@{ Valid = $false; Reason = 'unsupported backup schema'; Legacy = $false }
}

function Find-LatestValidMutationBackup {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    foreach ($candidate in (Get-ChildItem -LiteralPath $Root -Directory | Sort-Object LastWriteTimeUtc -Descending)) {
        $statePath = Join-Path $candidate.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try { $candidateState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $validation = Test-BackupState -State $candidateState -BackupPath $candidate.FullName
        if ($validation.Valid -and -not $validation.Legacy -and @($candidateState.completedMutations).Count -gt 0 -and
            (Test-Path -LiteralPath (Join-Path $candidate.FullName 'config.toml') -PathType Leaf)) { return $candidate.FullName }
    }
    return $null
}
