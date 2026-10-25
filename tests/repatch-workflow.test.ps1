[CmdletBinding()]
param([string]$ToolDir, [string]$NodePath = 'node', [string]$EvidencePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ToolDir) { $ToolDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'patcher' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runName = '{0}-ps{1}-{2}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $PSVersionTable.PSVersion.Major, $PID
$fixtureRoot = Join-Path $workspace ('.local/test-work/repatch-fixture-tests/' + $runName)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
if (-not $EvidencePath) { $EvidencePath = Join-Path $workspace ('.local/test-results/repatch-workflow-test-results-ps' + $PSVersionTable.PSVersion.Major + '.json') }
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EvidencePath))) | Out-Null
$buildScript = Join-Path $ToolDir 'Build-AppPatch.ps1'
$invokeScript = Join-Path $ToolDir 'Invoke-AppRepatch.ps1'
$applyScript = Join-Path $ToolDir 'Apply-AppPatch.ps1'
$restoreScript = Join-Path $ToolDir 'Restore-AppPatch.ps1'
$results = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureNumber = 0

function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
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
    $null = & $NodePath (Join-Path $PSScriptRoot 'repatch-fixture.cjs') $dir
    if ($LASTEXITCODE -ne 0) { throw 'Synthetic fixture creation failed.' }
    return (Get-Content -LiteralPath (Join-Path $dir 'fixture-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-Parameters {
    param($Fixture)
    return @{
        AppDir = $Fixture.appDir; LayerRoot = $Fixture.layerRoot; LayerSourceRoot = $Fixture.layerSourceRoot
        OutputDir = (Join-Path $Fixture.root 'prepared output'); NodePath = $NodePath; AsarModule = $Fixture.asarModule
    }
}
function Expect-Failure {
    param([scriptblock]$Action)
    try { $null = & $Action } catch { return $_.Exception.Message }
    throw 'Operation unexpectedly succeeded.'
}
function Run-Case {
    param([string]$Name, [scriptblock]$Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Action
        $results.Add([pscustomobject]@{ name = $Name; status = 'passed'; durationMs = $timer.ElapsedMilliseconds; detail = $detail })
        Write-Host ('PASS ' + $Name)
    } catch {
        $results.Add([pscustomobject]@{ name = $Name; status = 'failed'; durationMs = $timer.ElapsedMilliseconds; error = $_.Exception.Message; location = $_.ScriptStackTrace })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}

Run-Case 'Build WhatIf validates without creating output or touching inputs' {
    $f = New-Fixture 'build-whatif'
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.root
    $result = & $buildScript @parameters -WhatIf
    Assert-True ($result.status -eq 'validated-only') 'Unexpected status.'
    $expectedNode = @(Get-Command $NodePath -CommandType Application -ErrorAction Stop)[0].Source
    Assert-True ($result.nodePath -eq $expectedNode) 'Default NodePath did not select the first executable on PATH.'
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Build WhatIf wrote files.'
}
Run-Case 'Invoke WhatIf validates without output backups or app changes' {
    $f = New-Fixture 'invoke-whatif'
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.root
    $result = & $invokeScript @parameters -BackupRoot (Join-Path $f.root 'backups') -WhatIf
    Assert-True ($result.status -eq 'validated-only') 'Unexpected status.'
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Invoke WhatIf wrote files.'
}
Run-Case 'Build plus existing Apply and Restore round-trip exact app tree' {
    $f = New-Fixture 'build-apply-restore'
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.appDir
    $build = & $buildScript @parameters -Confirm:$false
    Assert-True ($build.status -eq 'prepared') 'Build did not produce prepared status.'
    Assert-True ((Get-TreeFingerprint $f.appDir) -eq $before) 'Build changed its source app.'
    Assert-True (Test-Path -LiteralPath $build.reportPath -PathType Leaf) 'Engine report not found at returned path.'
    $applied = & $applyScript -AppDir $f.appDir -PatchedAppDir $build.patchedAppDir -ManifestPath $build.manifestPath -BackupRoot (Join-Path $f.root 'backups') -Confirm:$false
    Assert-True ($applied.status -eq 'applied') 'Apply did not return applied status.'
    foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $f.appDir $relative)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $build.patchedAppDir $relative)).Hash) 'Applied bytes differ from generated pair.'
    }
    $restored = & $restoreScript -AppDir $f.appDir -BackupDir $applied.backupDir -Confirm:$false
    Assert-True ((Get-TreeFingerprint $f.appDir) -eq $before) 'Restore failed to recover exact source tree, including unpacked files.'
    return [pscustomobject]@{ fixture = $f.root; buildStatus = $build.status; applyStatus = $applied.status; restoreStatus = $restored.status; backupDir = $applied.backupDir }
}
Run-Case 'Invoke prepares applies backs up and Restore recovers Unicode-space paths' {
    $unicode = [string][char]0xd55c + [string][char]0xae00
    $f = New-Fixture ('invoke ' + $unicode + ' spaces')
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.appDir
    $applied = & $invokeScript @parameters -BackupRoot (Join-Path $f.root 'backups') -Confirm:$false
    Assert-True ($applied.status -eq 'applied') 'Invoke failed to apply.'
    Assert-True (Test-Path -LiteralPath $applied.backupDir -PathType Container) 'Backup missing.'
    $null = & $restoreScript -AppDir $f.appDir -BackupDir $applied.backupDir -Confirm:$false
    Assert-True ((Get-TreeFingerprint $f.appDir) -eq $before) 'Exact app tree did not survive round trip.'
    return [pscustomobject]@{ fixture = $f.root; status = $applied.status; backupDir = $applied.backupDir }
}
Run-Case 'existing output rejected without writes' {
    $f = New-Fixture 'existing-output'
    $parameters = Get-Parameters $f
    [IO.Directory]::CreateDirectory($parameters.OutputDir) | Out-Null
    [IO.File]::WriteAllText((Join-Path $parameters.OutputDir 'user-file'), 'keep me')
    $before = Get-TreeFingerprint $f.root
    $reason = Expect-Failure { & $buildScript @parameters -Confirm:$false }
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Rejected existing destination changed files.'
    return $reason
}
Run-Case 'output nested in target rejected before writes' {
    $f = New-Fixture 'output-overlap'
    $parameters = Get-Parameters $f
    $parameters.OutputDir = Join-Path $f.appDir 'nested output'
    $before = Get-TreeFingerprint $f.root
    $reason = Expect-Failure { & $buildScript @parameters -Confirm:$false }
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Rejected overlap changed files.'
    return $reason
}
Run-Case 'backup nested in target rejected before build or app writes' {
    $f = New-Fixture 'backup-overlap'
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.root
    $reason = Expect-Failure { & $invokeScript @parameters -BackupRoot (Join-Path $f.appDir 'backups') -Confirm:$false }
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Rejected backup path changed files.'
    return $reason
}
Run-Case 'locked EXE causes apply rollback and retains verified backup' {
    $f = New-Fixture 'locked-exe'
    $parameters = Get-Parameters $f
    $before = Get-TreeFingerprint $f.appDir
    $handle = [IO.File]::Open((Join-Path $f.appDir 'ChatGPT.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $reason = Expect-Failure { & $invokeScript @parameters -BackupRoot (Join-Path $f.root 'backups') -Confirm:$false } }
    finally { $handle.Dispose() }
    Assert-True ($reason -match 'Apply failed') 'Failure did not occur in Apply as expected.'
    Assert-True ((Get-TreeFingerprint $f.appDir) -eq $before) 'Rollback failed to recover original app tree.'
    $manifests = @(Get-ChildItem -LiteralPath (Join-Path $f.root 'backups') -Filter 'backup-manifest.json' -Recurse)
    Assert-True ($manifests.Count -eq 1) 'Verified backup manifest missing.'
    $metadata = Get-Content -LiteralPath $manifests[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($metadata.state -eq 'apply-failed-rolled-back') 'Backup does not record successful rollback.'
    return $reason
}
Run-Case 'WhatIf strips inherited Node preload side effects' {
    $f = New-Fixture 'node-options'
    $parameters = Get-Parameters $f
    $marker = Join-Path $f.root 'unwanted-preload-write'
    $preload = Join-Path $f.root 'unwanted-preload.cjs'
    $markerJson = ConvertTo-Json $marker -Compress
    [IO.File]::WriteAllText($preload, "require('node:fs').writeFileSync($markerJson,'bad');")
    $before = Get-TreeFingerprint $f.root
    $previous = [Environment]::GetEnvironmentVariable('NODE_OPTIONS', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('NODE_OPTIONS', ('--require="' + $preload + '"'), 'Process')
        $null = & $buildScript @parameters -WhatIf
    } finally { [Environment]::SetEnvironmentVariable('NODE_OPTIONS', $previous, 'Process') }
    Assert-True ((Get-TreeFingerprint $f.root) -eq $before) 'Node inherited preloader wrote during WhatIf.'
}

$evidence = [pscustomobject]@{
    schemaVersion = 1; createdAt = [DateTime]::UtcNow.ToString('o'); powerShellVersion = $PSVersionTable.PSVersion.ToString()
    fixtureRoot = $fixtureRoot; passed = @($results | Where-Object { $_.status -eq 'passed' }).Count
    failed = @($results | Where-Object { $_.status -eq 'failed' }).Count; tests = @($results.ToArray())
}
[IO.File]::WriteAllText($EvidencePath, ($evidence | ConvertTo-Json -Depth 25), (New-Object Text.UTF8Encoding($false)))
Write-Host ('RESULT passed={0} failed={1} evidence={2}' -f $evidence.passed, $evidence.failed, $EvidencePath)
if ($evidence.failed -gt 0) { exit 1 }
