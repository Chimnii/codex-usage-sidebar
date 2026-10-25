[CmdletBinding()]
param([string]$NodePath = 'node', [string]$EvidencePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runName = '{0}-ps{1}-{2}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $PSVersionTable.PSVersion.Major, $PID
$fixtureRoot = Join-Path $projectRoot ('.local/test-work/usage-environment/' + $runName)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
if (-not $EvidencePath) { $EvidencePath = Join-Path $projectRoot ('.local/test-results/usage-environment-test-results-ps' + $PSVersionTable.PSVersion.Major + '.json') }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EvidencePath))) | Out-Null
$results = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureNumber = 0
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Save-Json { param([string]$Path, $Value); [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 25), (New-Object Text.UTF8Encoding($false))) }
function Get-TreeFingerprint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $entries = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($root.Length)
        if ($item.PSIsContainer) { 'D:' + $relative }
        else { 'F:{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
    }
    return ($entries -join "`n")
}
function New-Fixture {
    param([string]$Name)
    $script:fixtureNumber++
    $dir = Join-Path $fixtureRoot ('{0:00}-{1}' -f $script:fixtureNumber, $Name)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $null = & $NodePath (Join-Path $PSScriptRoot 'usage-project-fixture.cjs') $dir $sid
    if ($LASTEXITCODE -ne 0) { throw 'Usage fixture creation failed.' }
    return (Get-Content -LiteralPath (Join-Path $dir 'usage-fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Invoke-Prepare { param($Fixture, [switch]$WhatIf); & (Join-Path $Fixture.projectRoot 'scripts/Prepare-UsageEnvironment.ps1') -ProjectRoot $Fixture.projectRoot -AppDir $Fixture.appDir -SettingsPath $Fixture.settingsPath -WhatIf:$WhatIf -Confirm:$false }
function Expect-Failure { param([scriptblock]$Action); try { $null = & $Action } catch { return $_.Exception.Message }; throw 'Operation unexpectedly succeeded.' }
function Run-Case {
    param([string]$Name, [scriptblock]$Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try { $detail = & $Action; $results.Add([pscustomobject]@{ name = $Name; status = 'passed'; durationMs = $timer.ElapsedMilliseconds; detail = $detail }); Write-Host ('PASS ' + $Name) }
    catch { $results.Add([pscustomobject]@{ name = $Name; status = 'failed'; durationMs = $timer.ElapsedMilliseconds; error = $_.Exception.Message; location = $_.ScriptStackTrace }); Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}

Run-Case 'WhatIf validates configuration without creating runtime or touching app profiles and files' {
    $f = New-Fixture 'whatif'
    $before = Get-TreeFingerprint $f.root
    $result = Invoke-Prepare $f -WhatIf
    Assert-True ($result.status -eq 'what-if') 'Unexpected WhatIf status.'
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'WhatIf changed files.'
}
Run-Case 'production collector paths bind selected app and account while preserving source and app bytes' {
    $f = New-Fixture 'paths'
    $beforeApp = Get-TreeFingerprint $f.appDir
    $beforeProfile = Get-TreeFingerprint $f.settings.userProfile
    $beforeRuntime = Get-TreeFingerprint $f.runtimeSource
    $result = Invoke-Prepare $f
    $config = Get-Content -LiteralPath $result.collectorConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($result.status -eq 'prepared') 'Unexpected prepare status.'
    Assert-True ($config.codexPath -eq (Join-Path $result.layerRoot 'bin/codex.exe')) 'Codex CLI does not target the owned unmodified CLI copy.'
    Assert-True ($config.originalCliPath -eq (Join-Path $f.appDir 'resources/codex.exe')) 'Wrong CLI source app.'
    $cliHash = (Get-FileHash -LiteralPath $config.codexPath -Algorithm SHA256).Hash
    Assert-True ($cliHash -eq (Get-FileHash -LiteralPath $config.originalCliPath -Algorithm SHA256).Hash) 'Copied CLI does not match app source.'
    Assert-True ($cliHash -eq $config.cliSha256 -and $cliHash -eq $result.copyHash) 'Wrong CLI hash metadata.'
    foreach ($key in @('nodePath','agyPath','codexHome','userProfile','localAppData','appData')) { Assert-True ($config.$key -eq $f.settings.$key) ('Wrong account setting ' + $key) }
    Assert-True ($config.intervalMs -eq 60000) 'Expected one minute refresh.'
    Assert-True ($config.projectRoot -eq $f.projectRoot) 'Updater must use this project entry point.'
    Assert-True ($config.workDir.StartsWith($result.layerRoot, [StringComparison]::OrdinalIgnoreCase)) 'Workdir escaped owned Layer root.'
    Assert-True ($config.cachePath -eq $result.cachePath) 'Wrong cache target.'
    Assert-True ($config.claudeCredentialsPath -eq (Join-Path $f.settings.userProfile '.claude/.credentials.json')) 'Claude must read the original credential location without copying credentials.'
    Assert-True ((Get-TreeFingerprint $f.appDir) -eq $beforeApp) 'Preparation mutated app.'
    Assert-True ((Get-TreeFingerprint $f.settings.userProfile) -eq $beforeProfile) 'Preparation mutated profile.'
    Assert-True ((Get-TreeFingerprint $f.runtimeSource) -eq $beforeRuntime) 'Preparation mutated source runtime.'
    $patched = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $result.runtimeRoot 'main.js') -Raw
    Assert-True ($patched.Contains('process.env.CODEX_HOME')) 'Runtime config path was not made CODEX_HOME aware.'
    Assert-True ($patched.Contains('MCP sync disabled') -and -not $patched.Contains('  syncMcpServersFromEnabledTweaks();')) 'Unused Layer MCP synchronization must not touch the shared profile.'
    $layerConfig = Get-Content -LiteralPath (Join-Path $result.layerRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not $layerConfig.codexPlusPlus.autoUpdate -and $layerConfig.tweaks.'local.sidebar-usage-demo'.enabled) 'Owned Layer runtime settings incorrect.'
    return $result
}
Run-Case 'second preparation preserves existing cache and user config byte for byte' {
    $f = New-Fixture 'preserve'
    $result = Invoke-Prepare $f
    [IO.File]::WriteAllText($result.cachePath, '{"cached":"keep exactly"}', (New-Object Text.UTF8Encoding($false)))
    $cacheHash = (Get-FileHash -LiteralPath $result.cachePath -Algorithm SHA256).Hash
    $profileBefore = Get-TreeFingerprint $f.settings.userProfile
    $null = Invoke-Prepare $f
    Assert-True ((Get-FileHash -LiteralPath $result.cachePath -Algorithm SHA256).Hash -eq $cacheHash) 'Existing cache overwritten.'
    Assert-True ((Get-TreeFingerprint $f.settings.userProfile) -eq $profileBefore) 'User settings overwritten.'
}
Run-Case 'usage preferences and explicit provider enablement reach the collector without changing profiles' {
    $f = New-Fixture 'usage-preferences'
    $settings = Get-Content -LiteralPath $f.settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings.agyPath = Join-Path $f.root 'missing-configured-agy.exe'
    $settings | Add-Member -NotePropertyName claudeEnabled -NotePropertyValue $false
    $settings | Add-Member -NotePropertyName usage -NotePropertyValue ([pscustomobject]@{language='en';hiddenProviders=@('antigravity');providers=[pscustomobject]@{codex=[pscustomobject]@{intervalSeconds=120}}})
    Save-Json $f.settingsPath $settings
    $before = Get-TreeFingerprint $f.settings.userProfile
    $result = Invoke-Prepare $f
    $config = Get-Content -LiteralPath $result.collectorConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($null -eq $config.agyPath -and $config.providerEnabled.antigravity) 'Missing configured executable must be distinguished from disabled provider.'
    Assert-True (-not $config.providerEnabled.claude -and $null -eq $config.claudeCredentialsPath) 'Explicitly disabled Claude must stay disabled.'
    Assert-True ($config.usage.language -eq 'en' -and $config.usage.providers.codex.intervalSeconds -eq 120) 'Usage preferences lost during preparation.'
    Assert-True ((Get-TreeFingerprint $f.settings.userProfile) -eq $before) 'Preferences preparation mutated shared profile.'
}
Run-Case 'updated selected app CLI replaces owned CLI copy without modifying the source' {
    $f = New-Fixture 'cli-update'
    $result = Invoke-Prepare $f
    $cliSource = Join-Path $f.appDir 'resources/codex.exe'
    [IO.File]::WriteAllText($cliSource, 'synthetic updated CLI - never executed')
    $sourceHash = (Get-FileHash -LiteralPath $cliSource -Algorithm SHA256).Hash
    $result = Invoke-Prepare $f
    Assert-True ((Get-FileHash -LiteralPath $result.codexPath -Algorithm SHA256).Hash -eq $sourceHash) 'Owned CLI did not refresh to selected version.'
    Assert-True ((Get-FileHash -LiteralPath $cliSource -Algorithm SHA256).Hash -eq $sourceHash) 'CLI source changed.'
}
Run-Case 'wrong account is rejected before creating runtime or modifying files' {
    $f = New-Fixture 'account-guard'
    $settings = Get-Content -LiteralPath $f.settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings.userSid = 'S-1-5-18'
    Save-Json $f.settingsPath $settings
    $before = Get-TreeFingerprint $f.root
    $reason = Expect-Failure { Invoke-Prepare $f }
    Assert-True ($reason -match 'Windows account') 'Wrong rejection reason.'
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Account guard wrote files.'
}
Run-Case 'unsupported or ambiguous runtime fails before any copy' {
    $f = New-Fixture 'runtime-guard'
    Add-Content -LiteralPath (Join-Path $f.runtimeSource 'runtime-paths.js') -Value 'exports.CODEX_CONFIG_FILE = (0, node_path_1.join)((0, node_os_1.homedir)(), ".codex", "config.toml");'
    $before = Get-TreeFingerprint $f.root
    $reason = Expect-Failure { Invoke-Prepare $f }
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Unsupported runtime wrote files.'
    return $reason
}
Run-Case 'runtime destination junction is rejected without touching its outside target' {
    $f = New-Fixture 'destination-junction'
    $outside = Join-Path $f.root 'outside-runtime'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'preserve outside')
    New-Item -ItemType Junction -Path (Join-Path $f.projectRoot '.local/layer-data') -Target $outside | Out-Null
    $outsideBefore = Get-TreeFingerprint $outside
    $reason = Expect-Failure { Invoke-Prepare $f }
    Assert-True ($reason -match 'reparse|junction|symbolic') 'Expected junction guard.'
    Assert-True ((Get-TreeFingerprint $outside) -eq $outsideBefore) 'Outside destination changed.'
}

$evidence = [pscustomobject]@{ schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o'); powerShellVersion = $PSVersionTable.PSVersion.ToString(); fixtureKind = 'synthetic project app and profiles; no real account usage requests'; fixtureRoot = $fixtureRoot; passed = @($results | Where-Object { $_.status -eq 'passed' }).Count; failed = @($results | Where-Object { $_.status -eq 'failed' }).Count; tests = @($results.ToArray()) }
Save-Json $EvidencePath $evidence
Write-Host ('RESULT passed={0} failed={1} evidence={2}' -f $evidence.passed, $evidence.failed, $EvidencePath)
if ($evidence.failed -gt 0) { exit 1 }
