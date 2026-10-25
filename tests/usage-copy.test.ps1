[CmdletBinding()]
param([string]$NodePath = 'node')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$run = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-ps' + $PSVersionTable.PSVersion.Major
$testRoot = Join-Path $workspace ('.local/test-work/shared-copy/' + $run)
[void][IO.Directory]::CreateDirectory($testRoot)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$null = & $NodePath (Join-Path $PSScriptRoot 'usage-project-fixture.cjs') (Join-Path $testRoot 'fixture') $sid
if ($LASTEXITCODE -ne 0) { throw 'Fixture creation failed.' }
$fixture = Get-Content -LiteralPath (Join-Path $testRoot 'fixture/usage-fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$project = $fixture.projectRoot
$sources = Join-Path $project '.local/tests'
[void][IO.Directory]::CreateDirectory($sources)
$v1 = Join-Path $sources 'source-v1'
Copy-Item -LiteralPath $fixture.appDir -Destination $v1 -Recurse
[void][IO.Directory]::CreateDirectory((Join-Path $v1 'resources/app.asar.unpacked/native'))
[IO.File]::WriteAllText((Join-Path $v1 'resources/app.asar.unpacked/native/example.node'), 'synthetic native payload')
[void][IO.Directory]::CreateDirectory((Join-Path $v1 'resources/empty-directory'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture.settings.appData 'Codex/web/Codex'))
[IO.File]::WriteAllText((Join-Path $fixture.settings.appData 'Codex/web/Codex/profile-sentinel'), 'synthetic web profile, preserve')
$script = Join-Path $project 'scripts/Prepare-UsageCopy.ps1'
$results = New-Object 'Collections.Generic.List[object]'
$script:first = $null
$script:second = $null
function Assert-True { param([bool]$Value,[string]$Message); if (-not $Value) { throw $Message } }
function Expect-Failure { param([scriptblock]$Action); try { $null = & $Action } catch { return $_.Exception.Message }; throw 'Expected operation to fail.' }
function Fingerprint {
    param([string]$Root)
    return (@(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($Root.Length) + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n")
}
function Run-Case {
    param([string]$Name,[scriptblock]$Action)
    try { $detail = & $Action; $results.Add([pscustomobject]@{ name=$Name; status='passed'; detail=$detail }); Write-Host "PASS $Name" }
    catch { $results.Add([pscustomobject]@{ name=$Name; status='failed'; error=$_.Exception.Message; location=$_.ScriptStackTrace }); Write-Host "FAIL $Name : $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}
$sourceBefore = Fingerprint $v1
$profileBefore = Fingerprint $fixture.settings.userProfile

Run-Case 'read-only planning does not create a copy or change user data' {
    $result = & $script -ProjectRoot $project -FixtureAppDir $v1 -AllowFixture -WhatIf
    Assert-True ($result.status -ceq 'planned') 'Wrong planning status.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $project '.local/copy'))) 'Planning created copy state.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'Planning changed the profile.'
}
Run-Case 'fresh copy patches only the owned app and uses the original profile paths' {
    $script:first = & $script -ProjectRoot $project -FixtureAppDir $v1 -AllowFixture -Confirm:$false
    Assert-True ($first.status -ceq 'prepared') 'Copy was not prepared.'
    Assert-True ((Fingerprint $v1) -ceq $sourceBefore) 'Installed source was changed.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'User profile was changed.'
    Assert-True ($first.copy.profiles.codexHome -ieq $fixture.settings.codexHome) 'Wrong Codex home.'
    $collector = Get-Content -Encoding UTF8 -LiteralPath (Join-Path $first.copy.layerRoot 'tweak-data/local.sidebar-usage-demo/collector-config.json') -Raw | ConvertFrom-Json
    Assert-True ($collector.codexHome -ieq $fixture.settings.codexHome) 'Collector uses an isolated test profile.'
    Assert-True ($collector.intervalMs -eq 60000) 'Refresh period changed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $first.copy.appDir 'resources/empty-directory') -PathType Container) 'Empty application directory was lost.'
    $native = 'resources/app.asar.unpacked/native/example.node'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $v1 $native)).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $first.copy.appDir $native)).Hash) 'Native payload was not copied exactly.'
}
Run-Case 'same installed version reuses the prepared copy without repatching' {
    $pointer = Join-Path $project '.local/copy/current.json'
    $before = [IO.File]::ReadAllText($pointer)
    $result = & $script -ProjectRoot $project -FixtureAppDir $v1 -AllowFixture -Confirm:$false
    Assert-True ($result.status -ceq 'reused' -and $result.copy.buildDir -ceq $first.copy.buildDir) 'Prepared copy was not reused.'
    Assert-True ([IO.File]::ReadAllText($pointer) -ceq $before) 'Reuse rewrote metadata.'
}
Run-Case 'launcher discards isolated profile flags and preserves native single-instance selection' {
    Import-Module (Join-Path $project 'scripts/UsageCopy.Common.psm1') -Force -DisableNameChecking
    $old = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH','Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH','poisoned-test-profile','Process')
        $start = New-UsageCopyStartInfo $first.copy $fixture.settings 'test-launch'
        Assert-True (-not $start.EnvironmentVariables.ContainsKey('CODEX_ELECTRON_USER_DATA_PATH')) 'Test override survived.'
        Assert-True ($start.EnvironmentVariables['CODEX_HOME'] -ieq $fixture.settings.codexHome) 'Wrong CODEX_HOME.'
        Assert-True ($start.EnvironmentVariables['APPDATA'] -ieq $fixture.settings.appData) 'Wrong APPDATA.'
        Assert-True ($start.EnvironmentVariables['CODEXPP_REMOTE_DEBUG'] -ceq '0') 'Debugging was enabled.'
        Assert-True ($start.EnvironmentVariables['SIDEBAR_USAGE_PACKAGE'] -ceq $first.copy.packageFullName) 'Update checker lost running source package identity.'
        Assert-True ($start.Arguments -ceq '') 'Profile/debug flags were injected.'
        Assert-True ($start.FileName -ieq (Join-Path $first.copy.appDir 'ChatGPT.exe')) 'Launcher targets installed app.'
    }
    finally { [Environment]::SetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH',$old,'Process') }
}

# Generate a different archive entry name and version to exercise structural
# repatching after a minor application update, not old patched-byte reuse.
$fixtureFactory = Join-Path $PSScriptRoot 'repatch-fixture.cjs'
$code = 'require(process.argv[2]).createFixture(process.argv[3],{version:"1.2.4",mainName:".vite/build/renamed-minor.js",versionNote:"minor v2"}).catch(e=>{console.error(e);process.exitCode=1})'
$generator = Join-Path $testRoot 'make-v2.cjs'
[IO.File]::WriteAllText($generator,$code)
$null = & $NodePath $generator $fixtureFactory (Join-Path $testRoot 'v2-input')
if ($LASTEXITCODE -ne 0) { throw 'v2 fixture creation failed.' }
$v2 = Join-Path $sources 'source-v2'
Copy-Item -LiteralPath (Join-Path $testRoot 'v2-input/clean app') -Destination $v2 -Recurse
Copy-Item -LiteralPath (Join-Path $v1 'resources/codex.exe') -Destination (Join-Path $v2 'resources/codex.exe')
Run-Case 'minor update keeps one app and reuses its CLI without duplicate binaries' {
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-True ($second.copy.buildDir -ceq $first.copy.buildDir -and $second.copy.generation -cne $first.copy.generation) 'Stable slot or fresh generation missing.'
    $base=Join-Path $project '.local/copy'
    foreach($name in @('previous','previous.json','retired','staging','active/original-pair','active/patch','active/layer-data/bin/codex.exe')) {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $base $name))) ('Unexpected duplicate: '+$name)
    }
    $collector=Read-AppJson (Join-Path $second.copy.layerRoot 'tweak-data/local.sidebar-usage-demo/collector-config.json')
    Assert-True ($collector.cliSource -ceq 'app') 'Collector must use the app CLI.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'Update changed user data.'
}
Run-Case 'stage-only preserves active and activates without rebuilding' {
    $base=Join-Path $project '.local/copy'; $before=Fingerprint (Join-Path $base 'active')
    $pending=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    Assert-True ((Fingerprint (Join-Path $base 'active')) -ceq $before) 'Staging changed active.'
    $old=Read-UsageCopyCurrent $project; $old.revision='old-active-revision'; Write-AppJson (Join-Path $base 'current.json') $old
    $script:second=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-True ($second.copy.generation -ceq $pending.copy.generation) 'Staged copy rebuilt.'
}
Run-Case 'interrupted swap restores the old active bytes before retry' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project
    $pending=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    Write-AppJson (Join-Path $base 'activation.json') @{operation='replace';old=$old;next=$pending.copy}
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination (Join-Path $base 'retired')
    Complete-UsageCopyActivation $project
    Assert-True ((Read-UsageCopyCurrent $project).generation -ceq $old.generation) 'Old active lost.'
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    Remove-UsageCopyDirectory $project (Join-Path $base 'staging')
}
Run-Case 'interrupted committed swap finishes metadata and removes retired files' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project
    $pending=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    Write-AppJson (Join-Path $base 'activation.json') @{operation='replace';old=$old;next=$pending.copy}
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination (Join-Path $base 'retired')
    Move-Item -LiteralPath (Join-Path $base 'staging') -Destination (Join-Path $base 'active')
    Complete-UsageCopyActivation $project
    $script:second.copy=Read-UsageCopyCurrent $project
    Assert-True ($second.copy.generation -ceq $pending.copy.generation) 'Committed app lost.'
    Assert-True (-not (Test-Path (Join-Path $base 'retired'))) 'Retired app retained.'
}
Run-Case 'invalid replacement rolls back before exposing a broken app' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project
    $pending=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    [IO.File]::AppendAllText((Join-Path $pending.copy.appDir 'ChatGPT.exe'),'broken')
    $reason=Expect-Failure { Publish-UsageCopy $project $pending.copy $old }
    Assert-True ($reason -match 'hash or length') 'Corrupt replacement accepted.'
    Assert-True ((Read-UsageCopyCurrent $project).generation -ceq $old.generation) 'Old app lost.'
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    Remove-UsageCopyDirectory $project (Join-Path $base 'staging')
}
Run-Case 'invalid receipt rolls back an update and rejects an incomplete first install' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project
    $pending=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    [IO.File]::WriteAllText((Join-Path $pending.copy.buildDir 'copy.json'),'{broken')
    $reason=Expect-Failure { Publish-UsageCopy $project $pending.copy $old }
    Assert-True ($reason -match 'receipt') 'Invalid update receipt accepted.'
    Assert-True ((Read-UsageCopyCurrent $project).generation -ceq $old.generation) 'Old active receipt lost.'
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    $held=Join-Path $testRoot 'held-active'
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination $held
    try {
        $reason=Expect-Failure { Publish-UsageCopy $project $pending.copy $null }
        Assert-True ($reason -match 'receipt') 'Invalid first install receipt accepted.'
        Assert-True (-not (Test-Path (Join-Path $base 'active'))) 'Invalid first install exposed.'
    } finally { Move-Item -LiteralPath $held -Destination (Join-Path $base 'active') }
    Remove-UsageCopyDirectory $project (Join-Path $base 'staging')
}
Run-Case 'file sharing failure leaves the selected app unchanged and cleans staging' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project; $before=Fingerprint $old.appDir
    $held=[IO.File]::Open((Join-Path $old.appDir 'ChatGPT.exe'),'Open','Read','Read')
    try { $reason=Expect-Failure { & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -ForceRebuild -Confirm:$false } }
    finally { $held.Dispose() }
    Assert-True ((Fingerprint $old.appDir) -ceq $before) 'Locked app changed.'
    Assert-True (-not (Test-Path (Join-Path $base 'staging'))) 'Failed staging retained.'
}
Run-Case 'cleanup rejects profile and active paths' {
    foreach($path in @($fixture.settings.userProfile,$second.copy.buildDir)) {
        $reason=Expect-Failure { Remove-UsageCopyDirectory $project $path }
        Assert-True ($reason -match 'unmanaged') 'Unexpected cleanup boundary.'
    }
}

Run-Case 'direct executable shortcut has no CMD arguments and has the copy AppUserModelID' {
    $lnk = Join-Path $testRoot 'test shortcut.lnk'
    $darkIcon=Join-Path $second.copy.appDir 'resources/chatgpt-app-dark.ico'
    $lightIcon=Join-Path $second.copy.appDir 'resources/chatgpt-app-light.ico'
    # Icon location properties do not decode the file. These are path-only fixtures.
    [IO.File]::WriteAllText($darkIcon,'synthetic dark icon')
    [IO.File]::WriteAllText($lightIcon,'synthetic light icon')
    $result = & (Join-Path $project 'scripts/Install-UsageShortcut.ps1') -ProjectRoot $project -OutputPath $lnk
    Assert-True ($result.target -ieq (Join-Path $second.copy.appDir 'ChatGPT.exe')) 'Not a direct EXE shortcut.'
    Assert-True ($result.arguments -ceq '' -and $result.appUserModelId -ceq 'Local.CodexUsageSidebar') 'Shell identity mismatch.'
    Assert-True ($result.displayName -ceq 'ChatGPT with usage') 'Copy display name is ambiguous.'
    Assert-True ([UsageSidebar.ShortcutProperties]::ReadDisplayName($lnk) -ceq 'ChatGPT with usage') 'Shell relaunch name not set.'
    Assert-True ($result.icon -in @($darkIcon,$lightIcon)) 'Shortcut did not use an original themed icon.'
    Assert-True ([UsageSidebar.ShortcutProperties]::ReadRelaunchIcon($lnk) -ceq ($result.icon+',0')) 'Relaunch icon differs from shortcut.'
    Assert-True ([UsageSidebar.ShortcutProperties]::GetIconPath($result.target,$true) -ceq $darkIcon) 'Dark system icon selection failed.'
    Assert-True ([UsageSidebar.ShortcutProperties]::GetIconPath($result.target,$false) -ceq $lightIcon) 'Light system icon selection failed.'
}

Run-Case 'shortcut migration updates owned pins and preserves original-app links' {
    $programs = Join-Path $testRoot 'shortcut-programs'
    $roaming = Join-Path $testRoot 'shortcut-roaming'
    $pins = Join-Path $roaming 'Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar'
    foreach ($folder in @($programs,$pins)) { [void][IO.Directory]::CreateDirectory($folder) }
    $exe = Join-Path $second.copy.appDir 'ChatGPT.exe'
    $oldMenu = Join-Path $programs 'Codex Usage Sidebar.lnk'
    $oldProject = Join-Path $project 'Codex Usage Sidebar.lnk'
    $pinned = Join-Path $pins 'ChatGPT.lnk'
    foreach ($link in @($oldMenu,$oldProject,$pinned)) { [UsageSidebar.ShortcutProperties]::Create($link,$exe,$second.copy.appDir) }
    $foreign = Join-Path $programs 'ChatGPT.lnk'
    $foreignPin = Join-Path $pins 'Original ChatGPT.lnk'
    foreach ($link in @($foreign,$foreignPin)) { [UsageSidebar.ShortcutProperties]::Create($link,(Join-Path $v1 'ChatGPT.exe'),$v1) }
    $foreignBefore = (Get-FileHash -LiteralPath $foreign).Hash
    $pinBefore = (Get-FileHash -LiteralPath $foreignPin).Hash
    # Redirect only the Windows Shell folders in this disposable fixture.
    $installer = Join-Path $project 'scripts/Install-UsageShortcut.ps1'
    $source = [IO.File]::ReadAllText($installer)
    $redirected = $source.Replace("[Environment]::GetFolderPath('Programs')", ("'" + $programs.Replace("'","''") + "'"))
    [IO.File]::WriteAllText($installer,$redirected)
    $previousAppData = $env:APPDATA
    try {
        $env:APPDATA = $roaming
        & $installer -ProjectRoot $project -UpdateExistingPin -WhatIf | Out-Null
        Assert-True ([IO.File]::Exists($oldMenu) -and -not [IO.File]::Exists((Join-Path $programs 'ChatGPT with usage.lnk'))) 'WhatIf changed shortcuts.'
        $null = & $installer -ProjectRoot $project -UpdateExistingPin
        Assert-True ([IO.File]::Exists((Join-Path $programs 'ChatGPT with usage.lnk'))) 'New Start-menu shortcut missing.'
        Assert-True (-not [IO.File]::Exists($oldMenu) -and -not [IO.File]::Exists($oldProject)) 'Owned legacy aliases remain.'
        Assert-True ([IO.File]::Exists($pinned) -and [UsageSidebar.ShortcutProperties]::ReadDisplayName($pinned) -ceq 'ChatGPT with usage') 'Existing pinned filename was not preserved and updated.'
        Assert-True ([UsageSidebar.ShortcutProperties]::ReadAppId($pinned) -ceq 'Local.CodexUsageSidebar') 'Pin grouping changed.'
        Assert-True ((Get-FileHash -LiteralPath $foreign).Hash -ceq $foreignBefore -and (Get-FileHash -LiteralPath $foreignPin).Hash -ceq $pinBefore) 'Original-app link changed.'
        Rename-Item -LiteralPath (Join-Path $programs 'ChatGPT with usage.lnk') -NewName 'ChatGPT with Usage.lnk'
        $null = & $installer -ProjectRoot $project -UpdateExistingPin
        Assert-True ([UsageSidebar.ShortcutProperties]::ReadDisplayName($pinned) -ceq 'ChatGPT with usage') 'Repeated shortcut setup failed.'
        Assert-True ((Get-Item -LiteralPath (Join-Path $programs 'ChatGPT with usage.lnk')).Name -ceq 'ChatGPT with usage.lnk') 'Old shortcut casing remains.'
    } finally { $env:APPDATA = $previousAppData; [IO.File]::WriteAllText($installer,$source) }
}

$badCode = 'require(process.argv[2]).createFixture(process.argv[3],{version:"1.2.5",mainSource:"module.exports={unsupported:true};"}).catch(e=>{console.error(e);process.exitCode=1})'
$badGenerator = Join-Path $testRoot 'make-v3.cjs'
[IO.File]::WriteAllText($badGenerator,$badCode)
$null = & $NodePath $badGenerator $fixtureFactory (Join-Path $testRoot 'v3-input')
if ($LASTEXITCODE -ne 0) { throw 'v3 fixture creation failed.' }
$v3 = Join-Path $sources 'source-v3'
Copy-Item -LiteralPath (Join-Path $testRoot 'v3-input/clean app') -Destination $v3 -Recurse
Copy-Item -LiteralPath (Join-Path $v1 'resources/codex.exe') -Destination (Join-Path $v3 'resources/codex.exe')
Run-Case 'unsupported update preserves selected build and source instead of publishing broken copy' {
    $pointer = Join-Path $project '.local/copy/current.json'
    $before = [IO.File]::ReadAllText($pointer)
    $source = Fingerprint $v3
    $reason = Expect-Failure { & $script -ProjectRoot $project -FixtureAppDir $v3 -FixtureVersion 'synthetic-v3' -AllowFixture -Confirm:$false }
    Assert-True ([IO.File]::ReadAllText($pointer) -ceq $before) 'Failed update replaced current selection.'
    Assert-True ((Fingerprint $v3) -ceq $source) 'Failed update modified source.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'Failed update modified user data.'
    return $reason
}
Run-Case 'damaged or missing app rebuilds from source without a previous version' {
    $old=Read-UsageCopyCurrent $project
    [IO.File]::AppendAllText((Join-Path $old.appDir 'ChatGPT.exe'),'tampered')
    $script:second=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-UsageCopyPair $second.copy
    Assert-True ($second.copy.generation -cne $old.generation) 'Damaged app reused.'
    Move-Item -LiteralPath $second.copy.buildDir -Destination (Join-Path $testRoot 'missing-slot')
    $script:second=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-UsageCopyPair $second.copy
}
Run-Case 'legacy backups are removed after successful preparation' {
    $base=Join-Path $project '.local/copy'; $old=Read-UsageCopyCurrent $project; $previous=Join-Path $base 'previous'
    $null=Copy-UsageAppTree $old.buildDir $previous
    Write-AppJson (Join-Path $base 'previous.json') (Convert-UsageCopyLocation $old $previous)
    $script:second=& $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -ForceRebuild -Confirm:$false
    Assert-True (-not (Test-Path $previous) -and -not (Test-Path (Join-Path $base 'previous.json'))) 'Legacy backup retained.'
}
Run-Case 'desktop process guard stops a shared-profile launch without killing any process' {
    Import-Module (Join-Path $project 'scripts/UsageCopy.Common.psm1') -Force -DisableNameChecking
    $module = Get-Module UsageCopy.Common | Select-Object -First 1
    & $module { function script:Get-UsageCopyBlockers { return @([pscustomobject]@{ ProcessId=12345; ExecutablePath='fixture' }) } }
    $reason = Expect-Failure { Assert-UsageCopyStopped }
    Assert-True ($reason -match 'Close ChatGPT / Codex completely') 'Desktop guard did not block launch.'
}
Run-Case 'missing original web profile fails instead of silently creating a new profile' {
    $other = $fixture.settings | Select-Object *
    $other.appData = Join-Path $testRoot 'nonexistent-profile'
    $reason = Expect-Failure { Get-UsageCopyProfiles $other }
    Assert-True (-not (Test-Path -LiteralPath $other.appData)) 'Missing profile was created.'
    return $reason
}

$outDir = Join-Path $workspace '.local/test-results'
[void][IO.Directory]::CreateDirectory($outDir)
$report = [pscustomobject]@{ checkedAt=[DateTime]::UtcNow.ToString('o'); powershell=$PSVersionTable.PSVersion.ToString(); fixtureRoot=$testRoot; results=@($results.ToArray()) }
[IO.File]::WriteAllText((Join-Path $outDir ('usage-copy-ps' + $PSVersionTable.PSVersion.Major + '.json')), ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
if (@($results | Where-Object status -CEQ 'failed').Count) { exit 1 }
