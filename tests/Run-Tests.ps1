#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\CodexReconnect.Common.ps1')

$script:Passed = 0
$script:Failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host ("PASS {0}" -f $Name); $script:Passed++ }
    catch { Write-Host ("FAIL {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red; $script:Failed++ }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'values differ')
    if ($Actual -ne $Expected) { throw ("{0}: expected '{1}', got '{2}'" -f $Message, $Expected, $Actual) }
}

function Assert-True { param([bool]$Value, [string]$Message = 'expected true') if (-not $Value) { throw $Message } }
function Assert-Throws { param([scriptblock]$Body) try { & $Body; throw 'expected an exception' } catch { if ($_.Exception.Message -eq 'expected an exception') { throw } } }

Test-Case 'standard TOML repair preserves CRLF and comments' {
    $input = "title = 'x'`r`n`r`n[features] # note`r`nrespect_system_proxy = false # keep`r`n"
    $plan = Get-RespectSystemProxyPlan -Text $input
    Assert-True $plan.Changed
    Assert-True ($plan.Text.Contains("respect_system_proxy = true # keep`r`n"))
    Assert-Equal ([regex]::Matches($plan.Text, '(?m)^\[features\]').Count) 1
}

Test-Case 'quoted TOML keys update one logical key' {
    $input = "['features']`n'respect_system_proxy' = false`n"
    $plan = Get-RespectSystemProxyPlan -Text $input
    Assert-True ($plan.Text.Contains("'respect_system_proxy' = true"))
    Assert-Equal (Get-RespectSystemProxyValue -Text $plan.Text) 'true'
}

Test-Case 'TOML keeps unrelated arrays and LF trailing-newline state' {
    $input = "[[mcp_servers]]`nname = 'demo'`n`n[features] # note`njs_repl = false"
    $plan = Get-RespectSystemProxyPlan -Text $input
    Assert-True ($plan.Text.StartsWith("[[mcp_servers]]`nname = 'demo'"))
    Assert-True (-not $plan.Text.EndsWith("`n"))
    Assert-Equal (Get-RespectSystemProxyValue -Text $plan.Text) 'true'
}

Test-Case 'dotted feature plus explicit table is refused' {
    Assert-Throws { Get-RespectSystemProxyPlan -Text "features.respect_system_proxy = false`n[features]`njs_repl = false`n" }
}

Test-Case 'unrelated TOML array tables remain supported' {
    $input = "[[projects]]`nname = 'one'`n[features]`nrespect_system_proxy = false`n"
    $plan = Get-RespectSystemProxyPlan -Text $input
    Assert-True ($plan.Text.Contains('[[projects]]'))
    Assert-Equal (Get-RespectSystemProxyValue -Text $plan.Text) 'true'
}

Test-Case 'duplicate TOML tables are refused' {
    Assert-Throws { Get-RespectSystemProxyPlan -Text "[features]`na=1`n[\"features\"]`nb=2`n" }
}

Test-Case 'non-boolean feature value is refused' {
    Assert-Throws { Get-RespectSystemProxyPlan -Text "[features]`nrespect_system_proxy = \"yes\"`n" }
}

Test-Case 'complex proxy routing is not safe to replace' {
    $classification = Get-ProxyServerClassification -ProxyServer 'http=127.0.0.1:7890;https=127.0.0.1:7891'
    Assert-True (-not $classification.SafeToReplace)
    Assert-Equal $classification.Kind 'complex'
}

Test-Case 'PAC-style uncertainty cannot be diagnosed OK' {
    Assert-Equal (Get-DiagnoseVerdict -RouteConfigured $false -RequiredProbeRan $true -RequiredProbePassed $true -HasFailure $false) 'UNVERIFIED'
}

Test-Case 'effective route prefers environment and supports ALL_PROXY' {
    $route = Get-EffectiveProxyRoute -Environment ([pscustomobject]@{ HTTPS_PROXY=''; ALL_PROXY='http://127.0.0.1:32123'; HTTP_PROXY='' }) -FeatureEnabled $false -ProxyEnable 0 -ProxyServer '' -AutoConfigUrl '' -AutoDetect 0
    Assert-Equal $route.Kind 'environment'
    Assert-Equal $route.Source 'ALL_PROXY'
    Assert-Equal $route.Port 32123
    Assert-True $route.Verifiable
}

Test-Case 'per-protocol route selects HTTPS endpoint' {
    $route = Get-EffectiveProxyRoute -Environment ([pscustomobject]@{ HTTPS_PROXY=''; ALL_PROXY=''; HTTP_PROXY='' }) -FeatureEnabled $true -ProxyEnable 1 -ProxyServer 'http=127.0.0.1:7890;https=127.0.0.1:47999' -AutoConfigUrl '' -AutoDetect 0
    Assert-Equal $route.Kind 'system-per-protocol'
    Assert-Equal $route.Port 47999
    Assert-True $route.Verifiable
}

Test-Case 'PAC and WPAD routes remain explicitly unverified' {
    $empty = [pscustomobject]@{ HTTPS_PROXY=''; ALL_PROXY=''; HTTP_PROXY='' }
    $pac = Get-EffectiveProxyRoute -Environment $empty -FeatureEnabled $true -ProxyEnable 1 -ProxyServer '127.0.0.1:7890' -AutoConfigUrl 'http://proxy/pac?token=secret' -AutoDetect 0
    $wpad = Get-EffectiveProxyRoute -Environment $empty -FeatureEnabled $true -ProxyEnable 1 -ProxyServer '127.0.0.1:7890' -AutoConfigUrl '' -AutoDetect 1
    Assert-True (-not $pac.Verifiable)
    Assert-True (-not $wpad.Verifiable)
}

Test-Case 'ALL_PROXY becomes the effective route' {
    $route = Get-EffectiveProxyRoute -Environment ([pscustomobject]@{ HTTPS_PROXY=''; HTTP_PROXY=''; ALL_PROXY='http://127.0.0.1:8080' }) -FeatureEnabled $false -ProxyEnable 0 -ProxyServer '' -AutoConfigUrl '' -AutoDetect 0
    Assert-Equal $route.Source 'ALL_PROXY'
    Assert-True $route.Verifiable
}

Test-Case 'skipped and failed probes cannot be diagnosed OK' {
    Assert-Equal (Get-DiagnoseVerdict -RouteConfigured $true -RequiredProbeRan $false -RequiredProbePassed $false -HasFailure $false) 'UNVERIFIED'
    Assert-Equal (Get-DiagnoseVerdict -RouteConfigured $true -RequiredProbeRan $true -RequiredProbePassed $false -HasFailure $false) 'UNVERIFIED'
}

Test-Case 'credential-bearing proxy values are redacted' {
    $safe = Protect-SensitiveText -Text 'HTTPS_PROXY=https://alice:secret@example.test:8443/path?access_token=xyz token=abc123'
    Assert-True (-not $safe.Contains('secret'))
    Assert-True (-not $safe.Contains('abc123'))
    Assert-True (-not $safe.Contains('xyz'))
}

Test-Case 'transaction rolls back completed mutations in reverse order' {
    $events = New-Object System.Collections.Generic.List[string]
    $operations = @(
        [pscustomobject]@{ Name='one'; Apply={ $events.Add('apply-one') }; Rollback={ $events.Add('undo-one') } },
        [pscustomobject]@{ Name='two'; Apply={ $events.Add('apply-two') }; Rollback={ $events.Add('undo-two') } },
        [pscustomobject]@{ Name='three'; Apply={ throw 'boom' }; Rollback={ $events.Add('undo-three') } }
    )
    $result = Invoke-RecoverableTransaction -Operations $operations
    Assert-True (-not $result.Succeeded)
    Assert-Equal ($events -join ',') 'apply-one,apply-two,undo-three,undo-two,undo-one'
}

Test-Case 'exact environment snapshot preserves existence and empty values' {
    $snapshot = [pscustomobject]@{
        HTTP_PROXY = [pscustomobject]@{ Exists = $true; Value = '' }
        HTTPS_PROXY = [pscustomobject]@{ Exists = $true; Value = 'http://old:1' }
        ALL_PROXY = [pscustomobject]@{ Exists = $false; Value = $null }
        NO_PROXY = [pscustomobject]@{ Exists = $true; Value = 'localhost' }
    }
    $plan = Get-EnvironmentRestorePlan -Snapshot $snapshot -Names @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    Assert-True $plan[0].Exists
    Assert-Equal $plan[0].Value ''
    Assert-True (-not $plan[2].Exists)
    Assert-Equal $plan[2].Value $null
    $plan = Get-EnvironmentRestorePlan -Snapshot $snapshot -Names @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY')
    Assert-True $plan[0].Exists
    Assert-Equal $plan[0].Value ''
    Assert-True (-not $plan[2].Exists)
    Assert-Equal $plan[2].Value $null
}

Test-Case 'malformed and partial rollback states are rejected' {
    Assert-True (-not (Test-BackupState -State $null -BackupPath '.').Valid)
    $partial = [pscustomobject]@{ schemaVersion=2; mutationId='x'; codexHome='C:\x'; completedMutations=@('config'); completed=$false }
    Assert-True (-not (Test-BackupState -State $partial -BackupPath '.').Valid)
}

Test-Case 'only complete mutation backups validate for automatic rollback' {
    $environment = [pscustomobject]@{
        HTTP_PROXY=[pscustomobject]@{Exists=$false;Value=$null}; HTTPS_PROXY=[pscustomobject]@{Exists=$false;Value=$null}
        ALL_PROXY=[pscustomobject]@{Exists=$false;Value=$null}; NO_PROXY=[pscustomobject]@{Exists=$false;Value=$null}
    }
    $state = [pscustomobject]@{
        schemaVersion=2; mutationId='abc'; codexHome='C:\codex'; configPath='C:\codex\config.toml'
        completedMutations=@('config'); completed=$true; environment=$environment
        proxyEnable=[pscustomobject]@{exists=$true;value=0}; proxyServer=[pscustomobject]@{exists=$true;value=''}
        autoConfigUrl=[pscustomobject]@{exists=$false;value=$null}; autoDetect=[pscustomobject]@{exists=$false;value=$null}
    }
    Assert-True (Test-BackupState -State $state -BackupPath '.').Valid
    $state.completedMutations = @()
    Assert-Equal @($state.completedMutations).Count 0
}

Test-Case 'launcher unblocks only its selected target' {
    foreach ($name in @('Fix.cmd', 'Diagnose.cmd', 'Rollback.cmd')) {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\$name") -Raw
        Assert-True ($text -match "Unblock-File -LiteralPath '%TARGET%'")
        Assert-True ($text -notmatch 'Get-ChildItem.+\*\.ps1')
    }
}

Test-Case 'CODEX_HOME is preferred over USERPROFILE' {
    $oldCodexHome = $env:CODEX_HOME
    $oldUserProfile = $env:USERPROFILE
    try {
        $env:CODEX_HOME = (Join-Path ([System.IO.Path]::GetTempPath()) 'codex-home-test')
        $env:USERPROFILE = (Join-Path ([System.IO.Path]::GetTempPath()) 'profile-test')
        Assert-Equal (Get-DefaultCodexHome) ([System.IO.Path]::GetFullPath($env:CODEX_HOME))
    } finally {
        $env:CODEX_HOME = $oldCodexHome
        $env:USERPROFILE = $oldUserProfile
    }
}

Test-Case 'argument bounds reject invalid ports and timeouts' {
    Assert-Throws { Assert-CodexReconnectParameters -Port 70000 -TimeoutSec 10 }
    Assert-Throws { Assert-CodexReconnectParameters -Port 7890 -TimeoutSec 0 }
}

Test-Case 'backup selection ignores newer empty and partial folders' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-reconnect-tests-' + [guid]::NewGuid().ToString('N'))
    try {
        $valid = New-Item -ItemType Directory -Path (Join-Path $root 'valid') -Force
        $partial = New-Item -ItemType Directory -Path (Join-Path $root 'partial') -Force
        $validState = [ordered]@{
            schemaVersion=2; mutationId='valid'; codexHome='C:\codex'; configPath='C:\codex\config.toml'
            completedMutations=@('config'); completed=$true
            proxyEnable=@{exists=$true;value=0}; proxyServer=@{exists=$true;value=''}
            autoConfigUrl=@{exists=$false;value=$null}; autoDetect=@{exists=$false;value=$null}
            environment=@{
                HTTP_PROXY=@{Exists=$false;Value=$null}; HTTPS_PROXY=@{Exists=$false;Value=$null}
                ALL_PROXY=@{Exists=$false;Value=$null}; NO_PROXY=@{Exists=$false;Value=$null}
            }
        }
        $partialState = [ordered]@{}; foreach ($key in $validState.Keys) { $partialState[$key] = $validState[$key] }
        $partialState.mutationId='partial'; $partialState.completed=$false
        [System.IO.File]::WriteAllText((Join-Path $valid.FullName 'state.json'), ($validState | ConvertTo-Json -Depth 8))
        [System.IO.File]::WriteAllText((Join-Path $valid.FullName 'config.toml'), '[features]')
        Start-Sleep -Milliseconds 20
        [System.IO.File]::WriteAllText((Join-Path $partial.FullName 'state.json'), ($partialState | ConvertTo-Json -Depth 8))
        Assert-Equal (Find-LatestValidMutationBackup -Root $root) $valid.FullName
    } finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0
