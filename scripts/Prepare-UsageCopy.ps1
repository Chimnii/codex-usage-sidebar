[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectRoot,
    [switch]$ForceRebuild,
    [switch]$StageOnly,
    [string]$FixtureAppDir,
    [string]$FixtureVersion = 'synthetic-v1',
    [switch]$AllowFixture
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$configuration = Get-UsageSettings $ProjectRoot
$ProjectRoot = $configuration.root
$target = Get-UsageTarget $configuration -FixtureAppDir $FixtureAppDir -AllowFixture:$AllowFixture
if ($AllowFixture) { $target.packageFullName = $FixtureVersion }
$profiles = Get-UsageCopyProfiles $configuration.value
$base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy') -AllowMissing
$revision = Get-UsageCopyRevision $ProjectRoot $configuration.value
$originals = @(foreach ($p in @('resources/app.asar','ChatGPT.exe')) { [pscustomobject]@{ path = $p; identity = (Get-AppIdentity (Get-AppPairPath $target.appDir $p)) } })
$current = $null
if (-not (Test-Path -LiteralPath (Join-Path $base 'activation.json'))) {
    try { $current = Read-UsageCopyCurrent $ProjectRoot -AllowMissingSlot } catch { if (-not $ForceRebuild) { throw } }
}
$matches = $null -ne $current -and $current.schemaVersion -eq 2 -and $current.packageFullName -ceq $target.packageFullName -and $current.sourceAppDir -ieq $target.appDir -and $current.revision -ceq $revision -and -not (Test-Path -LiteralPath (Join-Path $base 'activation.json'))
if ($matches) {
    foreach ($entry in $originals) {
        $old = @($current.originals | Where-Object path -CEQ $entry.path)
        if ($old.Count -ne 1 -or -not (Test-AppIdentity $entry.identity $old[0].identity)) { $matches = $false }
    }
}
if ($matches -and -not $ForceRebuild) {
    try {
        Assert-UsageCopyPair $current
        return [pscustomobject]@{ status = 'reused'; copy = $current }
    } catch { Write-Host 'The copy needs repair; rebuilding from the installed original.' }
}
if (-not $PSCmdlet.ShouldProcess($base, 'Create and verify a new patched copy; keep installed app and user profiles in place')) {
    return [pscustomobject]@{ status = 'planned'; sourceAppDir = $target.appDir; packageFullName = $target.packageFullName; profiles = $profiles }
}
[void][IO.Directory]::CreateDirectory($base)
$lock = [IO.File]::Open((Join-Path $base 'prepare.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$build = $null
$timer = [Diagnostics.Stopwatch]::StartNew()
$timings = [ordered]@{}
try {
    if ($StageOnly -and (Test-Path -LiteralPath (Join-Path $base 'activation.json'))) { throw 'Finish or recover the previous activation before staging another copy.' }
    if (-not $StageOnly) { Complete-UsageCopyActivation $ProjectRoot }
    try { $current = Read-UsageCopyCurrent $ProjectRoot -AllowMissingSlot } catch { if (-not $ForceRebuild) { throw }; $current = $null }
    if ($current -and $current.schemaVersion -eq 1) {
        # During the one-time migration, prefer the actually used legacy build
        # as the previous version. Keep it in place; it may still be running.
        $legacyApps = @(@(Get-UsageCopyBlockers) | Where-Object {
            $_.ExecutablePath -and (Test-AppPathInside $_.ExecutablePath (Join-Path $base 'builds'))
        } | Select-Object -ExpandProperty ExecutablePath -Unique)
        if ($legacyApps.Count -eq 1) {
            $legacyBuild = Split-Path (Split-Path $legacyApps[0] -Parent) -Parent
            if ((Split-Path $legacyBuild -Parent) -ine (Join-Path $base 'builds')) { throw 'Unexpected legacy app layout.' }
            $candidate = Read-AppJson (Join-Path $legacyBuild 'copy.json')
            if ($candidate.schemaVersion -ne 1 -or $candidate.buildDir -ine $legacyBuild -or
                $candidate.appDir -ine (Join-Path $legacyBuild 'app') -or $candidate.layerRoot -ine (Join-Path $legacyBuild 'layer-data')) { throw 'Invalid running legacy copy metadata.' }
            Assert-UsageCopyPair $candidate
            $current = $candidate
        }
    }
    # Initial migration can prepare a new slot while the legacy copy is open.
    # Subsequent replacements must never move the active running app.
    if (-not $StageOnly) { Assert-UsageCopySlotStopped (Join-Path $base 'active') }
    $stagePath = Join-Path $base 'staging'
    $stageReceipt = Join-Path $stagePath 'copy.json'
    if (-not $ForceRebuild -and [IO.File]::Exists($stageReceipt)) {
        $staged = Read-AppJson $stageReceipt
        if ($staged.schemaVersion -ne 2 -or $staged.kind -cne 'usage-shared-profile-copy' -or
            $staged.buildDir -ine $stagePath -or $staged.appDir -ine (Join-Path $stagePath 'app') -or
            $staged.layerRoot -ine (Join-Path $stagePath 'layer-data')) { throw 'Invalid staged copy paths.' }
        $same = $staged.revision -ceq $revision -and $staged.sourceAppDir -ieq $target.appDir -and $staged.packageFullName -ceq $target.packageFullName
        foreach ($entry in $originals) {
            $old = @($staged.originals | Where-Object path -CEQ $entry.path)
            if ($old.Count -ne 1 -or -not (Test-AppIdentity $entry.identity $old[0].identity)) { $same = $false }
        }
        if ($same) {
            Assert-UsageCopyPair $staged
            if ($StageOnly) { return [pscustomobject]@{ status='staged-reused'; copy=$staged } }
            $active = Publish-UsageCopy $ProjectRoot $staged $current
            return [pscustomobject]@{ status='prepared'; copy=$active }
        }
    }
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $build = Join-Path $base 'staging'
    Remove-UsageCopyDirectory $ProjectRoot $build
    [void][IO.Directory]::CreateDirectory($build)
    Write-Host '[1/3] Copying app resources with Windows robocopy.'
    $timer.Restart()
    # Generate the patched pair directly from the Store source. Its clean
    # bytes never need to be copied into this disposable staging directory.
    $files = @(Copy-UsageAppTree $target.appDir (Join-Path $build 'app') -SkipPatchPair)
    $timings.copySeconds = [Math]::Round($timer.Elapsed.TotalSeconds,2); $timer.Restart()
    Write-Host "Copied resources ($($timings.copySeconds)s)."
    Write-Host '[2/3] Preparing Layer and usage collection.'
    $environment = & (Join-Path $PSScriptRoot 'Prepare-UsageEnvironment.ps1') -ProjectRoot $ProjectRoot -AppDir $target.appDir -LayerDataRoot (Join-Path $build 'layer-data') -ManagedAppDir (Join-Path $build 'app') -AllowFixture:$AllowFixture -Confirm:$false
    $collectorConfig = Read-AppJson $environment.collectorConfigPath
    $collectorConfig | Add-Member -NotePropertyName managedCopy -NotePropertyValue $true
    $collectorConfig | Add-Member -NotePropertyName cliSource -NotePropertyValue 'app'
    $collectorConfig.codexPath = '../../../app/resources/codex.exe'
    $collectorConfig.workDir = '../../collector-work'
    $collectorConfig.cachePath = 'usage-cache.json'
    Write-AppJson $environment.collectorConfigPath $collectorConfig
    Write-AppJson (Join-Path $build 'copy-startup.json') ([pscustomobject]@{
        schemaVersion=1; appUserModelId='Local.CodexUsageSidebar'; packageFullName=$target.packageFullName; sourceAppDir=$target.appDir
        projectRoot=$ProjectRoot
        environment=@{ APPDATA=$configuration.value.appData; LOCALAPPDATA=$configuration.value.localAppData; USERPROFILE=$configuration.value.userProfile; CODEX_HOME=$profiles.codexHome }
    })
    # Reuse only sanitized usage cache; authentication and application data stay at
    # their original paths. Failure to carry an old cache leaves unknown values.
    $previousCache = Join-Path $ProjectRoot '.local/layer-data/tweak-data/local.sidebar-usage-demo/usage-cache.json'
    if ($null -ne $current) { $previousCache = Join-Path $current.layerRoot 'tweak-data/local.sidebar-usage-demo/usage-cache.json' }
    if ([IO.File]::Exists($previousCache)) { [IO.File]::Copy($previousCache, $environment.cachePath, $false) }
    $timings.environmentSeconds = [Math]::Round($timer.Elapsed.TotalSeconds,2); $timer.Restart()
    Write-Host "Prepared usage collection ($($timings.environmentSeconds)s)."
    Write-Host '[3/3] Patching the new app.'
    $patched = & (Join-Path $ProjectRoot 'patcher/Build-AppPatch.ps1') -AppDir $target.appDir -LayerRoot $environment.layerRoot -LayerSourceRoot $environment.layerSourceRoot -OutputDir (Join-Path $build 'patch') -NodePath $environment.nodePath -AsarModule $environment.asarModule -PortableCopy -ManagedCopy -Confirm:$false
    if ($patched.status -cne 'prepared') { throw 'Copy patch was not prepared.' }
    $manifest = Read-AppPatchManifest $patched.manifestPath
    foreach ($entry in $manifest.files) {
        $to = Join-Path (Join-Path $build 'app') $entry.path
        if ([IO.File]::Exists($to)) { throw 'A patch destination was unexpectedly copied.' }
        [IO.File]::Move((Get-AppPairPath $patched.patchedAppDir $entry.path),$to)
    }
    $manifestPath = Join-Path $build 'patch-manifest.json'
    [IO.File]::Move($patched.manifestPath,$manifestPath)
    [IO.File]::Move($patched.reportPath,(Join-Path $build 'repatch-report.json'))
    foreach ($relative in @('patch/app/resources','patch/app','patch')) { [IO.Directory]::Delete((Join-Path $build $relative),$false) }
    # A concurrent Store update must not publish a build as the current version.
    $latest = Get-UsageTarget $configuration -FixtureAppDir $FixtureAppDir -AllowFixture:$AllowFixture
    if ($AllowFixture) { $latest.packageFullName = $FixtureVersion }
    if ($latest.packageFullName -cne $target.packageFullName -or $latest.appDir -ine $target.appDir) { throw 'Installed version changed during preparation.' }
    # The engine checks its source before and after patching. Match that snapshot
    # to the one taken before copying, without rereading the large ASAR again.
    foreach ($entry in $originals) {
        $builtFrom = @($manifest.files | Where-Object path -CEQ $entry.path)
        if ($builtFrom.Count -ne 1 -or -not (Test-AppIdentity $entry.identity $builtFrom[0].original)) { throw 'Installed source changed between copying and patching.' }
    }
    if ((Get-UsageCopyRevision $ProjectRoot $configuration.value) -cne $revision) { throw 'Project sources changed during preparation. Run preparation again.' }
    $timings.patchSeconds = [Math]::Round($timer.Elapsed.TotalSeconds,2)
    $receipt = [pscustomobject]@{
        schemaVersion = 2; storagePolicy = 'single-copy'; generation = $id; kind = 'usage-shared-profile-copy'; preparedAt = [DateTime]::UtcNow.ToString('o')
        buildDir = $build; appDir = (Join-Path $build 'app'); layerRoot = $environment.layerRoot
        sourceAppDir = $target.appDir; packageFullName = $target.packageFullName; revision = $revision
        profiles = $profiles; originals = $originals; sourceFileCount = $files.Count
        patched = @($manifest.files | ForEach-Object { [pscustomobject]@{ path = $_.path; identity = $_.patched } })
        manifestPath = $manifestPath; backupDir = $null; timings = $timings
    }
    Write-AppJson (Join-Path $build 'copy.json') $receipt -CreateNew
    if ($StageOnly) { Assert-UsageCopyPair $receipt; return [pscustomobject]@{ status='staged'; copy=$receipt } }
    $timer.Restart()
    $active = Publish-UsageCopy $ProjectRoot $receipt $current
    Write-Host "Patched ($($timings.patchSeconds)s), activated and cleaned up ($([Math]::Round($timer.Elapsed.TotalSeconds,2))s)."
    return [pscustomobject]@{ status = 'prepared'; copy = $active }
}
catch {
    $failure = $_
    Write-AppJson (Join-Path $base 'last-prepare-error.json') ([pscustomobject]@{ at = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message; location = $_.ScriptStackTrace })
    if ($build -and -not (Test-Path -LiteralPath (Join-Path $base 'activation.json'))) {
        try { Remove-UsageCopyDirectory $ProjectRoot $build } catch { Write-Warning 'Temporary staging files could not be removed; the next preparation will retry cleanup.' }
    }
    throw $failure
}
finally { $lock.Dispose() }
