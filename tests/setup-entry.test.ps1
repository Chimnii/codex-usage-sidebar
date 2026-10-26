[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$shell = (Get-Process -Id $PID).Path
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$utf8 = New-Object Text.UTF8Encoding($false)
$work = Join-Path $root ('.local/test-work/setup-entry/' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$results = New-Object 'Collections.Generic.List[object]'
function Assert-True([bool]$value, [string]$message) { if (-not $value) { throw $message } }
function Case([string]$name, [scriptblock]$action) {
    try { & $action; $results.Add(@{name=$name;status='passed'}); Write-Host "PASS $name" }
    catch { $results.Add(@{name=$name;status='failed';error=$_.Exception.Message;location=$_.ScriptStackTrace}); Write-Host "FAIL $name : $($_.Exception.Message)" }
}
function Write-FixtureFile([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Get-TreeFingerprint([string]$path) {
    return (@(Get-ChildItem -LiteralPath $path -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($path.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
}
function New-SetupFixture([string]$name) {
    $directory = Join-Path $work $name
    & node (Join-Path $PSScriptRoot 'usage-project-fixture.cjs') $directory $sid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Setup fixture generation failed.' }
    $f = Get-Content -LiteralPath (Join-Path $directory 'usage-fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    [void][IO.Directory]::CreateDirectory((Join-Path $f.settings.appData 'Codex/web/Codex'))
    Write-FixtureFile (Join-Path $f.settings.codexHome 'keep.txt') 'profile sentinel'
    # Replace only external adapters in this disposable project: package lookup,
    # live-process discovery, dependency downloads and Windows shortcut creation.
    # Setup and the full copy/patch/settings pipeline remain production code.
    $adapter = @'
function Get-UsageTarget {
    param($Configuration, [string]$FixtureAppDir, [switch]$AllowFixture)
    $fixture = Get-Content -LiteralPath (Join-Path (Split-Path $Configuration.root -Parent) 'usage-fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return [pscustomobject]@{appDir=$fixture.appDir;packageFullName='synthetic-setup-v1';fixture=$true}
}
Export-ModuleMember -Function Get-UsageSettings, Get-UsageTarget
'@
    [IO.File]::AppendAllText((Join-Path $f.projectRoot 'scripts/Environment.Common.psm1'), "`n" + $adapter, $utf8)
    $processAdapter = @'
function Get-UsageCopyBlockers {
    $file=Join-Path (Split-Path $PSScriptRoot -Parent) '.local/process-fixture.json'
    if ([IO.File]::Exists($file)) { return @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) }
    return @()
}
Export-ModuleMember -Function *-UsageCopy*, Copy-UsageAppTree
'@
    [IO.File]::AppendAllText((Join-Path $f.projectRoot 'scripts/UsageCopy.Common.psm1'), "`n"+$processAdapter, $utf8)
    Write-FixtureFile (Join-Path $f.projectRoot 'scripts/Install-Dependencies.ps1') @'
param([string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$fixture = Get-Content -LiteralPath (Join-Path (Split-Path $ProjectRoot -Parent) 'usage-fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Write-AppJson (Join-Path $ProjectRoot '.local/dependencies-fixture.json') @{prepared=$true}
return [pscustomobject]@{nodePath=$fixture.settings.nodePath}
'@
    Write-FixtureFile (Join-Path $f.projectRoot 'scripts/Install-UsageShortcut.ps1') @'
param([string]$ProjectRoot, [switch]$UpdateExistingPin)
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
Write-AppJson (Join-Path $ProjectRoot '.local/shortcut-fixture.json') @{prepared=$true;updateExistingPin=[bool]$UpdateExistingPin}
'@
    return $f
}
$runner = Join-Path $work 'run-entry.ps1'
Write-FixtureFile $runner @'
param([string]$FixtureInfo, [ValidateSet('setup','dependencies','uninstall-plan')][string]$Action)
$ErrorActionPreference = 'Stop'
$fixture = Get-Content -LiteralPath $FixtureInfo -Raw -Encoding UTF8 | ConvertFrom-Json
# New-process entry: do not preload modules or commands from the test runner.
foreach ($key in @('USERPROFILE','APPDATA','LOCALAPPDATA','CODEX_HOME')) {
    $value = switch ($key) {
        'USERPROFILE' { $fixture.settings.userProfile }
        'APPDATA' { $fixture.settings.appData }
        'LOCALAPPDATA' { $fixture.settings.localAppData }
        'CODEX_HOME' { $fixture.settings.codexHome }
    }
    [Environment]::SetEnvironmentVariable($key, $value, 'Process')
}
if ($Action -eq 'uninstall-plan') {
    & (Join-Path $fixture.projectRoot 'scripts/Uninstall.ps1') -ProjectRoot $fixture.projectRoot -WhatIf
} else {
    $result = & (Join-Path $fixture.projectRoot 'scripts/Setup.ps1') -ProjectRoot $fixture.projectRoot -DependenciesOnly:($Action -eq 'dependencies')
    [IO.File]::WriteAllText((Join-Path $fixture.projectRoot '.local/setup-result.json'), ($result | ConvertTo-Json -Depth 16))
}
'@
function Invoke-Entry($fixture, [string]$action) {
    $log = Join-Path (Split-Path $fixture.projectRoot -Parent) ($action + '.log')
    & $shell -NoProfile -ExecutionPolicy Bypass -File $runner -FixtureInfo (Join-Path (Split-Path $fixture.projectRoot -Parent) 'usage-fixture-info.json') -Action $action *> $log
    if ($LASTEXITCODE -ne 0) { throw ('Fresh-process entry failed: ' + [IO.File]::ReadAllText($log)) }
}
function Assert-Prepared($fixture) {
    $result = Get-Content -LiteralPath (Join-Path $fixture.projectRoot '.local/setup-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($result.status -eq 'prepared') 'Setup did not finish full copy preparation.'
    Assert-True ([IO.File]::Exists((Join-Path $result.copy.appDir 'ChatGPT.exe'))) 'Prepared executable missing.'
    foreach ($entry in $result.copy.patched) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $result.copy.appDir $entry.path)).Hash -ceq $entry.identity.sha256) 'Published patch identity mismatch.'
    }
    $shortcut = Get-Content -LiteralPath (Join-Path $fixture.projectRoot '.local/shortcut-fixture.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($shortcut.prepared -and $shortcut.updateExistingPin) 'Setup did not reach shortcut adapter.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $fixture.settings.codexHome 'keep.txt')) -ceq 'profile sentinel') 'Setup changed shared profile.'
}
Case 'existing settings setup succeeds in a fresh process and preserves preferences' {
    $f = New-SetupFixture 'existing'
    $f.settings | Add-Member -NotePropertyName usage -NotePropertyValue ([pscustomobject]@{language='ko';hiddenProviders=@('claude')})
    $f.settings | Add-Member -NotePropertyName claudeEnabled -NotePropertyValue $false
    Write-FixtureFile $f.settingsPath ($f.settings | ConvertTo-Json -Depth 8)
    $original = Get-TreeFingerprint $f.appDir
    Invoke-Entry $f setup
    Assert-Prepared $f
    $saved = Get-Content -LiteralPath $f.settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($saved.usage.language -eq 'ko' -and $saved.usage.hiddenProviders[0] -eq 'claude' -and -not $saved.claudeEnabled) 'Existing preferences changed.'
    Assert-True ((Get-TreeFingerprint $f.appDir) -ceq $original) 'Setup changed original app fixture.'
}
Case 'new settings setup succeeds in a fresh process with optional providers absent' {
    $f = New-SetupFixture 'fresh'
    # This exact synthetic settings file was just created by New-SetupFixture.
    [IO.File]::Delete($f.settingsPath)
    Invoke-Entry $f setup
    Assert-Prepared $f
    $saved = Get-Content -LiteralPath $f.settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($saved.usage.language -eq 'auto' -and $saved.claudeEnabled -and $null -eq $saved.agyPath) 'Fresh setup optional defaults changed.'
    Assert-True ($saved.codexHome -eq $f.settings.codexHome -and $saved.appData -eq $f.settings.appData) 'Fresh setup used the real profile.'
}
Case 'setup can prepare while the original is running and warns without touching it' {
    $f = New-SetupFixture 'original-running'
    Write-FixtureFile (Join-Path $f.projectRoot '.local/process-fixture.json') (@(@{ProcessId=12345;ExecutablePath=(Join-Path $f.appDir 'ChatGPT.exe')}) | ConvertTo-Json)
    $before=Get-TreeFingerprint $f.appDir
    Invoke-Entry $f setup
    Assert-Prepared $f
    Assert-True ((Get-TreeFingerprint $f.appDir) -ceq $before) 'Running original was changed.'
    $log=[IO.File]::ReadAllText((Join-Path (Split-Path $f.projectRoot -Parent) 'setup.log'))
    Assert-True ($log -match 'original ChatGPT app is still running') 'Missing original-running completion warning.'
    $startup=Get-Content -LiteralPath (Join-Path $f.projectRoot '.local/copy/active/copy-startup.json') -Raw | ConvertFrom-Json
    Assert-True ($startup.sourceAppDir -ceq $f.appDir) 'Direct-launch guard lost original executable location.'
}
Case 'setup refuses to replace a running managed copy before installing or changing settings' {
    $f = New-SetupFixture 'copy-running'
    Write-FixtureFile (Join-Path $f.projectRoot '.local/process-fixture.json') (@(@{ProcessId=12345;ExecutablePath=(Join-Path $f.projectRoot '.local/copy/active/app/ChatGPT.exe')}) | ConvertTo-Json)
    $before=[IO.File]::ReadAllText($f.settingsPath)
    $failure=$null
    try { Invoke-Entry $f setup } catch { $failure=$_.Exception.Message }
    Assert-True ($failure -match 'Close ChatGPT with usage') 'Running copy was not blocked clearly.'
    Assert-True ([IO.File]::ReadAllText($f.settingsPath) -ceq $before) 'Blocked setup changed settings.'
    Assert-True (-not [IO.File]::Exists((Join-Path $f.projectRoot '.local/dependencies-fixture.json'))) 'Blocked setup installed dependencies.'
}
Case 'an optional completion warning lookup failure does not fail completed setup' {
    $f = New-SetupFixture 'warning-lookup-failure'
    [IO.File]::AppendAllText((Join-Path $f.projectRoot 'scripts/UsageCopy.Common.psm1'), "`nfunction Get-UsageCopyOriginalProcesses { throw 'Synthetic warning lookup failure' }`nExport-ModuleMember -Function *-UsageCopy*, Copy-UsageAppTree`n", $utf8)
    Invoke-Entry $f setup
    Assert-Prepared $f
}
Case 'dependency-only fresh entry does not create settings or copies' {
    $f = New-SetupFixture 'dependencies'
    [IO.File]::Delete($f.settingsPath)
    Invoke-Entry $f dependencies
    Assert-True ([IO.File]::Exists((Join-Path $f.projectRoot '.local/dependencies-fixture.json'))) 'Dependency adapter was not called.'
    Assert-True (-not [IO.File]::Exists($f.settingsPath)) 'Dependency-only entry created settings.'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $f.projectRoot '.local/copy'))) 'Dependency-only entry prepared an app copy.'
    Assert-True (-not [IO.File]::Exists((Join-Path $f.projectRoot '.local/shortcut-fixture.json'))) 'Dependency-only entry created shortcuts.'
}
Case 'uninstall planning with existing settings succeeds in a fresh process without mutations' {
    $f = New-SetupFixture 'uninstall'
    $base = Join-Path $f.projectRoot '.local/copy'
    [void][IO.Directory]::CreateDirectory($base)
    Write-FixtureFile (Join-Path $base 'keep.txt') 'copy sentinel'
    $before = Get-TreeFingerprint $f.projectRoot
    Invoke-Entry $f uninstall-plan
    Assert-True ((Get-TreeFingerprint $f.projectRoot) -ceq $before) 'Uninstall planning mutated the project.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $f.settings.codexHome 'keep.txt')) -ceq 'profile sentinel') 'Uninstall planning changed profile.'
}
$out = Join-Path $root ('.local/test-results/setup-entry-ps' + $PSVersionTable.PSVersion.Major + '.json')
[void][IO.Directory]::CreateDirectory((Split-Path $out -Parent))
Write-FixtureFile $out (@{results=@($results.ToArray())} | ConvertTo-Json -Depth 8)
if (@($results | Where-Object status -eq 'failed').Count) { exit 1 }
