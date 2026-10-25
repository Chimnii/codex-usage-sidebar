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
Run-Case 'minor update keeps the executable path fixed and retains one previous version' {
    $oldApp = Fingerprint $first.copy.appDir
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-True ($second.status -ceq 'prepared' -and $second.copy.buildDir -ceq $first.copy.buildDir -and $second.copy.generation -cne $first.copy.generation) 'Stable slot or fresh patch missing.'
    Assert-True ($second.copy.packageFullName -ceq 'synthetic-v2') 'Wrong update version.'
    $previous = Read-UsageCopyCurrent $project previous
    Assert-True ((Fingerprint $previous.appDir) -ceq $oldApp) 'Backup does not contain the previous app.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'Update changed the original user data.'
    $backupAsar = Get-ChildItem -LiteralPath $second.copy.backupDir -Filter 'app.asar' -Recurse | Select-Object -First 1
    Assert-True ($null -ne $backupAsar) 'Fresh source backup missing.'
    Assert-True ((Get-FileHash -LiteralPath $backupAsar.FullName).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $v2 'resources/app.asar')).Hash) 'Update backup does not match new version.'
}

Run-Case 'third activation replaces the older backup and keeps exactly two complete slots' {
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -ForceRebuild -Confirm:$false
    $previous = Read-UsageCopyCurrent $project previous
    Assert-True ($previous.packageFullName -ceq 'synthetic-v2') 'Oldest backup was retained.'
    Assert-True (-not (Test-Path (Join-Path $project '.local/copy/retired'))) 'Retired backup was not removed.'
    Assert-True (-not (Test-Path (Join-Path $project '.local/copy/staging'))) 'Staging was not consumed.'
    Assert-True (-not (Test-Path (Join-Path $project '.local/copy/builds'))) 'Versioned builds were created.'
}

Run-Case 'stage-only prepares a pending copy without touching the active app or either pointer' {
    $base = Join-Path $project '.local/copy'
    $before = Fingerprint (Join-Path $base 'active')
    $currentText = [IO.File]::ReadAllText((Join-Path $base 'current.json'))
    $previousText = [IO.File]::ReadAllText((Join-Path $base 'previous.json'))
    $script:pending = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -StageOnly -ForceRebuild -Confirm:$false
    Assert-True ($pending.status -ceq 'staged') 'Copy was not staged.'
    Assert-True ((Fingerprint (Join-Path $base 'active')) -ceq $before) 'Staging changed active app.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $base 'current.json')) -ceq $currentText) 'Staging changed current pointer.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $base 'previous.json')) -ceq $previousText) 'Staging changed previous pointer.'
}

Run-Case 'pending source revision is activated on the next normal preparation without a rebuild' {
    # Simulate a source revision prepared in staging while the active copy was open.
    $base = Join-Path $project '.local/copy'
    $old = Read-UsageCopyCurrent $project
    $old.revision = 'earlier-active-revision'
    Write-AppJson (Join-Path $base 'current.json') $old
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-True ($second.copy.generation -ceq $pending.copy.generation) 'Prepared staging was unnecessarily rebuilt.'
    Assert-True (-not (Test-Path (Join-Path $base 'staging'))) 'Staging was not activated.'
    Assert-True ((Read-UsageCopyCurrent $project previous).generation -ceq $old.generation) 'Activation lost the previous app.'
}

Run-Case 'interrupted directory swap restores the full old active slot' {
    $base = Join-Path $project '.local/copy'
    $active = Read-UsageCopyCurrent $project
    $oldPrevious = Read-UsageCopyCurrent $project previous
    $journal = @{old=$active;next=@{generation='never-committed'}}
    Write-AppJson (Join-Path $base 'activation.json') $journal
    Move-Item -LiteralPath (Join-Path $base 'previous') -Destination (Join-Path $base 'retired')
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination (Join-Path $base 'previous')
    Complete-UsageCopyActivation $project
    $restored = Read-UsageCopyCurrent $project
    Assert-UsageCopyPair $restored
    Assert-True ($restored.generation -ceq $active.generation) 'Wrong active version recovered.'
    Assert-True ((Read-UsageCopyCurrent $project previous).generation -ceq $oldPrevious.generation) 'Previous backup was not recovered.'
}

Run-Case 'cleanup rejects paths outside managed temporary directories' {
    $reason = Expect-Failure { Remove-UsageCopyDirectory $project $fixture.settings.userProfile }
    Assert-True ($reason -match 'unmanaged') 'Unmanaged directory accepted.'
    Assert-True ((Fingerprint $fixture.settings.userProfile) -ceq $profileBefore) 'Profile changed.'
}

Run-Case 'interrupted publish after the new directory is active completes its metadata' {
    $base = Join-Path $project '.local/copy'
    $active = Read-UsageCopyCurrent $project
    $previous = Read-UsageCopyCurrent $project previous
    $next = Convert-UsageCopyLocation $active (Join-Path $base 'staging')
    $next.generation = 'simulated-committed-generation'
    Write-AppJson (Join-Path $base 'active/copy.json') $next
    Write-AppJson (Join-Path $base 'activation.json') @{old=$previous;next=$next}
    Complete-UsageCopyActivation $project
    $script:second.copy = Read-UsageCopyCurrent $project
    Assert-UsageCopyPair $second.copy
    Assert-True ($second.copy.generation -ceq $next.generation) 'Committed active version was lost.'
    Assert-True (-not (Test-Path (Join-Path $base 'activation.json'))) 'Activation journal was not completed.'
}

Run-Case 'file sharing failure cannot replace the running slot bytes and recovery retains both versions' {
    $base = Join-Path $project '.local/copy'
    $old = Read-UsageCopyCurrent $project
    $oldPrevious = Read-UsageCopyCurrent $project previous
    $before = (Get-FileHash -LiteralPath (Join-Path $old.appDir 'ChatGPT.exe')).Hash
    $held = [IO.File]::Open((Join-Path $old.appDir 'ChatGPT.exe'),'Open','Read','Read')
    try {
        $reason = Expect-Failure { & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -ForceRebuild -Confirm:$false }
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $old.appDir 'ChatGPT.exe')).Hash -ceq $before) 'Failed rename changed active app.'
    } finally { $held.Dispose() }
    Complete-UsageCopyActivation $project
    Assert-True ((Read-UsageCopyCurrent $project).generation -ceq $old.generation) 'Recovery changed active generation.'
    Assert-True ((Read-UsageCopyCurrent $project previous).generation -ceq $oldPrevious.generation) 'Recovery lost previous backup.'
    Remove-UsageCopyDirectory $project (Join-Path $base 'staging')
}

Run-Case 'direct executable shortcut has no CMD arguments and has the copy AppUserModelID' {
    $lnk = Join-Path $testRoot 'test shortcut.lnk'
    $result = & (Join-Path $project 'scripts/Install-UsageShortcut.ps1') -ProjectRoot $project -OutputPath $lnk
    Assert-True ($result.target -ieq (Join-Path $second.copy.appDir 'ChatGPT.exe')) 'Not a direct EXE shortcut.'
    Assert-True ($result.arguments -ceq '' -and $result.appUserModelId -ceq 'Local.CodexUsageSidebar') 'Shell identity mismatch.'
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
Run-Case 'tampered prepared executable is rejected before reuse' {
    $exe = Join-Path $second.copy.appDir 'ChatGPT.exe'
    $bytes = [IO.File]::ReadAllBytes($exe)
    try {
        [IO.File]::AppendAllText($exe, 'tampered')
        $reason = Expect-Failure { & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false }
        Assert-True ($reason -match 'hash or length') 'Corrupt copy did not fail hash validation.'
    }
    finally { [IO.File]::WriteAllBytes($exe,$bytes) }
}
Run-Case 'preparation entry recovers a missing active slot before reading its pointer' {
    $base = Join-Path $project '.local/copy'
    $old = Read-UsageCopyCurrent $project
    Write-AppJson (Join-Path $base 'activation.json') @{old=$old;next=@{generation='uncommitted-entry-test'}}
    Move-Item -LiteralPath (Join-Path $base 'previous') -Destination (Join-Path $base 'retired')
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination (Join-Path $base 'previous')
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-UsageCopyPair $second.copy
    Assert-True ((Read-UsageCopyCurrent $project previous).generation -ceq $old.generation) 'Interrupted active slot was not retained as backup.'
}
Run-Case 'one-time legacy migration keeps the previous folder intact and removes other legacy builds' {
    $base = Join-Path $project '.local/copy'
    $old = Read-UsageCopyCurrent $project
    $legacy = Join-Path $base 'builds/legacy-fixture'
    [void][IO.Directory]::CreateDirectory((Split-Path $legacy -Parent))
    Move-Item -LiteralPath (Join-Path $base 'active') -Destination $legacy
    $old = Convert-UsageCopyLocation $old $legacy
    $old.schemaVersion = 1
    Write-AppJson (Join-Path $legacy 'copy.json') $old
    Write-AppJson (Join-Path $base 'current.json') $old
    $before = Fingerprint $legacy
    [void][IO.Directory]::CreateDirectory((Join-Path $base 'builds/unused-legacy-fixture'))
    $script:second = & $script -ProjectRoot $project -FixtureAppDir $v2 -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    Assert-True ((Fingerprint $legacy) -ceq $before) 'Legacy backup was altered.'
    Assert-True ((Read-UsageCopyCurrent $project previous).buildDir -ieq $legacy) 'Legacy backup was not selected.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $base 'builds') -Directory).Count -eq 1) 'Extra legacy backups remain.'
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
