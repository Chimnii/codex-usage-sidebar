[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$work=Join-Path $root ('.local/test-work/release-setup/'+[guid]::NewGuid().ToString('N'))
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& node (Join-Path $PSScriptRoot 'usage-project-fixture.cjs') $work $sid | Out-Null
if($LASTEXITCODE -ne 0){throw 'Fixture failed'}
$f=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $work 'usage-fixture-info.json') -Raw | ConvertFrom-Json
$project=$f.projectRoot
$utf8=New-Object Text.UTF8Encoding($false)
$settings=$f.settings
function Save-Settings { [IO.File]::WriteAllText($f.settingsPath,($settings|ConvertTo-Json -Depth 8),$utf8) }
function Assert-True([bool]$v,[string]$message){if(-not $v){throw $message}}
$results=New-Object 'Collections.Generic.List[object]'
function Case([string]$name,[scriptblock]$action){try{&$action;$results.Add(@{name=$name;status='passed'});Write-Host "PASS $name"}catch{$results.Add(@{name=$name;status='failed';error=$_.Exception.Message;location=$_.ScriptStackTrace});Write-Host "FAIL $name : $($_.Exception.Message)"}}
Case 'no optional provider is required to prepare the collector' {
    $settings.agyPath=$null;$settings|Add-Member -Force -NotePropertyName claudeEnabled -NotePropertyValue $false;Save-Settings
    $r=& (Join-Path $project 'scripts/Prepare-UsageEnvironment.ps1') -ProjectRoot $project -AppDir $f.appDir -Confirm:$false
    $c=Get-Content -Encoding UTF8 -LiteralPath $r.collectorConfigPath -Raw | ConvertFrom-Json
    Assert-True ($null -eq $c.agyPath -and $null -eq $c.claudeCredentialsPath) 'Optional providers were enabled'
    Assert-True (Test-Path -LiteralPath (Join-Path $r.tweakRoot 'collector/collect.cjs')) 'Separate collector was not assembled'
}
Case 'missing Antigravity path and absent Claude credentials do not block preparation' {
    $settings.agyPath=Join-Path $work 'missing/agy.exe';$settings.claudeEnabled=$true;Save-Settings
    $r=& (Join-Path $project 'scripts/Prepare-UsageEnvironment.ps1') -ProjectRoot $project -AppDir $f.appDir -Confirm:$false
    $c=Get-Content -Encoding UTF8 -LiteralPath $r.collectorConfigPath -Raw | ConvertFrom-Json
    Assert-True ($null -eq $c.agyPath) 'Missing CLI was required'
    Assert-True (-not (Test-Path -LiteralPath $c.claudeCredentialsPath)) 'A credential file was created'
}
# Only this disposable project's process adapter is mocked. No real app is closed.
[IO.File]::AppendAllText((Join-Path $project 'scripts/UsageCopy.Common.psm1'),"`nfunction Get-UsageCopyBlockers { return @() }`nExport-ModuleMember -Function *-UsageCopy*, Copy-UsageAppTree`n",$utf8)
Import-Module (Join-Path $project 'scripts/UsageCopy.Common.psm1') -Force -DisableNameChecking
[void][IO.Directory]::CreateDirectory((Join-Path $settings.appData 'Codex/web/Codex'))
[IO.File]::WriteAllText((Join-Path $settings.codexHome 'keep.txt'),'profile sentinel',$utf8)
$source=Join-Path $project '.local/tests/app'
[void][IO.Directory]::CreateDirectory((Split-Path $source -Parent))
Copy-Item -LiteralPath $f.appDir -Destination $source -Recurse
$prepare=Join-Path $project 'scripts/Prepare-UsageCopy.ps1'
Case 'previous version restoration preserves shared profile and enables a hold' {
    $a=& $prepare -ProjectRoot $project -FixtureAppDir $source -FixtureVersion 'synthetic-v1' -AllowFixture -Confirm:$false
    $b=& $prepare -ProjectRoot $project -FixtureAppDir $source -FixtureVersion 'synthetic-v2' -AllowFixture -Confirm:$false
    $restored=& (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -Confirm:$false
    Assert-True ($restored.packageFullName -eq 'synthetic-v1') 'Previous version not selected'
    $hold=Get-Content -Encoding UTF8 -LiteralPath (Join-Path $project '.local/copy/restore-hold.json') -Raw | ConvertFrom-Json
    Assert-True ($hold.generation -eq $restored.generation) 'Hold missing'
    Assert-True ([IO.File]::ReadAllText((Join-Path $settings.codexHome 'keep.txt')) -eq 'profile sentinel') 'Profile changed'
}
Case 'launch respects the restored version instead of preparing the current original' {
    $launcher=Join-Path $project 'scripts/Start-UsageCopy.ps1'
    $text=[IO.File]::ReadAllText($launcher).Replace('$process = [Diagnostics.Process]::Start($start)',"throw 'fixture-launch-boundary'")
    [IO.File]::WriteAllText($launcher,$text,$utf8)
    $caught=$null;try{& $launcher -ProjectRoot $project}catch{$caught=$_.Exception.Message}
    Assert-True ($caught -eq 'fixture-launch-boundary') ('Hold did not reach launch boundary: '+$caught)
}
function Get-TreeFingerprint([string]$path) {
    return (@(Get-ChildItem -LiteralPath $path -File -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($path.Length)+':'+(Get-FileHash -LiteralPath $_.FullName).Hash
    }) -join "`n")
}
function Assert-OwnedTestPath([string]$path) {
    $full=Assert-AppPlainPath $path -AllowMissing
    if (-not (Test-AppPathInside $full $project)) { throw 'Fixture boundary violation' }
    return $full
}
Case 'damaged active executable is quarantined while the verified rollback remains unchanged' {
    $current=Read-UsageCopyCurrent $project
    $previous=Read-UsageCopyCurrent $project previous
    $backup=Get-TreeFingerprint $previous.buildDir
    [IO.File]::AppendAllText((Join-Path $current.appDir 'ChatGPT.exe'),'damaged fixture')
    Write-AppJson (Join-Path $current.buildDir 'copy.json') @{interrupted='incomplete active metadata'}
    $broken=(Get-FileHash -LiteralPath (Join-Path $current.appDir 'ChatGPT.exe')).Hash
    $restored=& (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -Confirm:$false
    Assert-UsageCopyPair $restored
    Assert-True ((Get-TreeFingerprint $previous.buildDir) -ceq $backup) 'Repair replaced the good rollback'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $project '.local/copy/damaged/app/ChatGPT.exe')).Hash -ceq $broken) 'Damaged active was not preserved'
    Assert-True ($restored.generation -like 'repair-*') 'Repair has no distinct generation'
}
Case 'missing active app can be restored without losing the rollback backup' {
    $current=Read-UsageCopyCurrent $project
    $previous=Read-UsageCopyCurrent $project previous
    $backup=Get-TreeFingerprint $previous.buildDir
    $from=Assert-OwnedTestPath $current.buildDir
    $to=Assert-OwnedTestPath (Join-Path $project '.local/tests/removed-active')
    Move-Item -LiteralPath $from -Destination $to
    $restored=& (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -Confirm:$false
    Assert-UsageCopyPair $restored
    Assert-True ((Get-TreeFingerprint $previous.buildDir) -ceq $backup) 'Missing-slot repair replaced rollback'
}
Case 'repair crash after quarantining active resumes and keeps a verified backup' {
    $base=Join-Path $project '.local/copy'
    $previous=Read-UsageCopyCurrent $project previous
    $backup=Get-TreeFingerprint $previous.buildDir
    $stage=Join-Path $base 'staging'
    $null=Copy-UsageAppTree $previous.buildDir $stage
    $next=Convert-UsageCopyLocation $previous $stage
    $next.generation='repair-interrupted-before-publish'
    Write-AppJson (Join-Path $stage 'copy.json') $next
    Write-AppJson (Join-Path $base 'activation.json') @{operation='repair';next=$next;previousGeneration=$previous.generation}
    $from=Assert-OwnedTestPath (Join-Path $base 'active')
    $to=Assert-OwnedTestPath (Join-Path $base 'damaged')
    Move-Item -LiteralPath $from -Destination $to
    $before=Get-TreeFingerprint $base
    & (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -WhatIf
    Assert-True ((Get-TreeFingerprint $base) -ceq $before) 'Restore planning changed interrupted repair state'
    $resumed=& (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -Confirm:$false
    Assert-True ($resumed.generation -eq $next.generation) 'Restore did not return resumed repair generation'
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    Assert-True ((Read-UsageCopyCurrent $project).generation -eq $next.generation) 'Repair was not resumed'
    Assert-True ((Get-TreeFingerprint $previous.buildDir) -ceq $backup) 'Recovery changed rollback'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $base 'activation.json'))) 'Repair journal remains'
}
Case 'repair crash after activation completes pointers and restore hold' {
    $base=Join-Path $project '.local/copy'
    $previous=Read-UsageCopyCurrent $project previous
    $current=Read-UsageCopyCurrent $project
    $next=Convert-UsageCopyLocation $current (Join-Path $base 'staging')
    $next.generation='repair-interrupted-after-publish'
    Write-AppJson (Join-Path $base 'active/copy.json') $next
    Write-AppJson (Join-Path $base 'activation.json') @{operation='repair';next=$next;previousGeneration=$previous.generation}
    Complete-UsageCopyActivation $project
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    Assert-True ((Read-AppJson (Join-Path $base 'restore-hold.json')).generation -eq $next.generation) 'Repair hold missing after recovery'
}
Case 'Launch recovers a missing active slot before selecting the restored version' {
    $base=Join-Path $project '.local/copy'
    $previous=Read-UsageCopyCurrent $project previous
    $stage=Join-Path $base 'staging'
    $null=Copy-UsageAppTree $previous.buildDir $stage
    $next=Convert-UsageCopyLocation $previous $stage
    $next.generation='repair-launch-entry'
    Write-AppJson (Join-Path $stage 'copy.json') $next
    Remove-UsageCopyDirectory $project (Join-Path $base 'damaged')
    Write-AppJson (Join-Path $base 'activation.json') @{operation='repair';next=$next;previousGeneration=$previous.generation}
    $from=Assert-OwnedTestPath (Join-Path $base 'active')
    $to=Assert-OwnedTestPath (Join-Path $base 'damaged')
    Move-Item -LiteralPath $from -Destination $to
    $caught=$null;try { & (Join-Path $project 'scripts/Start-UsageCopy.ps1') -ProjectRoot $project } catch { $caught=$_.Exception.Message }
    Assert-True ($caught -eq 'fixture-launch-boundary') ('Launch did not recover before selection: '+$caught)
    Assert-UsageCopyPair (Read-UsageCopyCurrent $project)
    Assert-True ((Read-UsageCopyCurrent $project).generation -eq $next.generation) 'Launch selected wrong generation'
}
Case 'invalid backup cannot replace current and outside metadata is still rejected' {
    $base=Join-Path $project '.local/copy'
    $previous=Read-UsageCopyCurrent $project previous
    $current=Read-UsageCopyCurrent $project
    $before=Get-TreeFingerprint $current.buildDir
    $exe=Join-Path $previous.appDir 'ChatGPT.exe'
    $bytes=[IO.File]::ReadAllBytes($exe)
    try {
        [IO.File]::AppendAllText($exe,'tampered backup')
        $caught=$null;try { & (Join-Path $project 'scripts/Restore-Copy.ps1') -ProjectRoot $project -Confirm:$false } catch { $caught=$_.Exception.Message }
        Assert-True ($caught -match 'hash or length') 'Damaged backup was accepted'
        Assert-True ((Get-TreeFingerprint $current.buildDir) -ceq $before) 'Rejected repair changed active'
    } finally { [IO.File]::WriteAllBytes($exe,$bytes) }
    $pointer=Join-Path $base 'current.json'
    $receipt=[IO.File]::ReadAllText($pointer)
    try {
        $current.buildDir=$settings.userProfile
        Write-AppJson $pointer $current
        $caught=$null;try { Read-UsageCopyCurrent $project -AllowMissingSlot } catch { $caught=$_.Exception.Message }
        Assert-True ($caught -match 'fixed slot') 'AllowMissingSlot weakened path checks'
    } finally { [IO.File]::WriteAllText($pointer,$receipt,$utf8) }
}
Case 'runtime revision ignores documentation and tests but includes runtime settings and loader' {
    $original=Get-UsageCopyRevision $project $settings
    $doc=Join-Path $project 'collector/README.md'
    $test=Join-Path $project 'collector/collector.test.cjs'
    [IO.File]::AppendAllText($doc,"`nDocumentation change")
    [IO.File]::AppendAllText($test,"`n// test-only change")
    Assert-True ((Get-UsageCopyRevision $project $settings) -ceq $original) 'Nonruntime change repatches app'
    $settings|Add-Member -Force -NotePropertyName usage -NotePropertyValue ([pscustomobject]@{language='en'})
    $configured=Get-UsageCopyRevision $project $settings
    Assert-True ($configured -cne $original) 'Usage settings missing from revision'
    [IO.File]::AppendAllText((Join-Path $project 'collector/collect.cjs'),"`n// runtime change")
    $runtime=Get-UsageCopyRevision $project $settings
    Assert-True ($runtime -cne $configured) 'Runtime change missing from revision'
    $loader=@('assets/loader.cjs','packages/loader/loader.cjs','packages/installer/assets/loader.cjs') | ForEach-Object {Join-Path (Join-Path $project '.local/layer-source') $_} | Where-Object {[IO.File]::Exists($_)} | Select-Object -First 1
    [IO.File]::AppendAllText($loader,"`n// loader change")
    Assert-True ((Get-UsageCopyRevision $project $settings) -cne $runtime) 'Loader change missing from revision'
}
Case 'app readiness is independent of disabled or unauthenticated providers' {
    $copy=Read-UsageCopyCurrent $project
    $launch=[pscustomobject]@{startedAt=[DateTime]::UtcNow.AddMinutes(-2).ToString('o');appDir=$copy.appDir;profiles=$copy.profiles}
    $status=[pscustomobject]@{runtime=@{userData=$copy.profiles.webProfile;codexHome=$copy.profiles.codexHome;executable=(Join-Path $copy.appDir 'ChatGPT.exe')};ui=@{detectorVersion=2;visiblePanels=1;withinSidebar=$true;snagDetected=$false};cycles=2;active=$false;updatedAt=[DateTime]::UtcNow.ToString('o');providers=@(@{id='codex';status='unavailable'},@{id='antigravity';status='disconnected'},@{id='claude';status='unavailable'})} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $config=[pscustomobject]@{agyPath=$null;claudeCredentialsPath='configured-missing';providerEnabled=[pscustomobject]@{antigravity=$false;claude=$true}}
    $health=Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config
    Assert-True (@($health.checks.PSObject.Properties | Where-Object {$_.Value -ne $true}).Count -eq 0) 'Provider authentication failed app readiness'
    Assert-True (($health.providerHealth | Where-Object id -eq 'antigravity').status -eq 'disabled') 'Disabled provider not distinguished'
    Assert-True (($health.providerHealth | Where-Object id -eq 'claude').status -eq 'unavailable') 'Enabled unavailable provider hidden'
    $config.providerEnabled.antigravity=$true
    Assert-True ((Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config).providerHealth[1].enabled) 'Missing executable ignored configured enablement'
    $status.cycles=1;$status | Add-Member -NotePropertyName intervalMs -NotePropertyValue 300000
    $slow=Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config
    Assert-True ($slow.checks.collectorRefresh -and $slow.refreshObservation.intervalMs -eq 300000 -and $slow.refreshObservation.cycles -eq 1) 'Long configured interval falsely failed readiness'
    $status.active=$true
    Assert-True (-not (Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config).checks.collectorRefresh) 'Active collection counted as completed refresh'
    $status.ui | Add-Member -NotePropertyName hiddenBySettings -NotePropertyValue $true
    $status.ui | Add-Member -NotePropertyName mountedPanels -NotePropertyValue 1
    $status.ui.visiblePanels=0;$status.ui.withinSidebar=$false
    Assert-True (Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config).checks.sidebarPanel 'Intentionally hidden providers failed UI readiness'
    $status.ui.mountedPanels=0
    Assert-True (-not (Get-UsageCopyReadiness $launch $status @($copy.profiles.webProfile) $config).checks.sidebarPanel) 'Missing UI mount accepted as intentional hiding'
}
Case 'launch history is bounded and keeps the current report and unrelated files' {
    $base=Join-Path $project '.local/copy'
    $launches=Join-Path $base 'launches'
    [void][IO.Directory]::CreateDirectory($launches)
    $first=$null
    for($i=0;$i -lt 25;$i++) {
        $name=[DateTime]::UtcNow.AddDays(-25+$i).ToString('yyyyMMddTHHmmssfffZ')+'-'+$i.ToString('x8')+'.json'
        $path=Join-Path $launches $name
        [IO.File]::WriteAllText($path,'{}',$utf8)
        [IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddDays(-25+$i))
        if($i -eq 0){$first=$path}
    }
    Write-AppJson (Join-Path $base 'last-launch.json') @{launchPath=$first}
    [IO.File]::WriteAllText((Join-Path $launches 'keep-user-notes.json'),'{}',$utf8)
    Remove-UsageCopyOldLaunchReports $project
    Assert-True ([IO.File]::Exists($first)) 'Current report deleted'
    Assert-True (@(Get-ChildItem -LiteralPath $launches -File).Count -eq 22) 'Unexpected report retention'
    Assert-True ([IO.File]::Exists((Join-Path $launches 'keep-user-notes.json'))) 'Unowned name removed'
}
Case 'Doctor reads local state without leaking paths raw errors or account data' {
    $copy=Read-UsageCopyCurrent $project
    $data=Join-Path $copy.layerRoot 'tweak-data/local.sidebar-usage-demo'
    $marker='PRIVATE-SENTINEL-DO-NOT-EXPORT'
    Write-AppJson (Join-Path $data 'usage-cache.json') @{version=1;providers=@(@{id='codex';status='unavailable';errorCode='RPC_ERROR';error=$marker;windows=@(@{label=$marker})})}
    Write-AppJson (Join-Path $data 'bridge-status.json') @{runtime=@{userData=$settings.appData;credential=$marker};ui=@{visiblePanels=1;withinSidebar=$true;snagDetected=$false;reportedAt=[DateTime]::UtcNow.ToString('o')};cycles=2;active=$false;updateMenuEntries=1}
    Write-AppJson (Join-Path $data 'update-status.json') @{status='current';storeStatus='current';storeError=$marker;storeCheckedAt=[DateTime]::UtcNow.ToString('o')}
    # Suppress even read-only installed-package discovery outside this fixture.
    function Get-AppxPackage { param($Name,$ErrorAction); return @() }
    $before=Get-TreeFingerprint $project
    $json=& (Join-Path $project 'scripts/Doctor.ps1') -ProjectRoot $project -Json
    $report=$json | ConvertFrom-Json
    Assert-True ($report.copyIntegrity -eq 'verified' -and $report.repairAvailable) 'Doctor missed verified app/rollback'
    Assert-True ($report.providers[0].errorCode -eq 'RPC_ERROR') 'Doctor discarded safe collector error code'
    Assert-True ($report.update.storeStatus -eq 'current' -and $null -eq $report.update.storeError) 'Doctor did not sanitize Store diagnostics'
    Assert-True ($json -notmatch [regex]::Escape($marker) -and $json -notmatch [regex]::Escape($project) -and $json -notmatch [regex]::Escape($settings.userProfile)) 'Doctor leaked private data'
    Assert-True ((Get-TreeFingerprint $project) -ceq $before) 'Doctor wrote project data'
    $bridge=Read-AppJson (Join-Path $data 'bridge-status.json')
    $bridge | Add-Member -NotePropertyName providers -NotePropertyValue @([pscustomobject]@{id='codex';status='stale';errorCode='TIMEOUT'})
    Write-AppJson (Join-Path $data 'bridge-status.json') $bridge
    $currentReport=(& (Join-Path $project 'scripts/Doctor.ps1') -ProjectRoot $project -Json) | ConvertFrom-Json
    Assert-True ($currentReport.providers[0].status -eq 'stale' -and $currentReport.providers[0].errorCode -eq 'TIMEOUT') 'Doctor preferred older cache over current bridge failure'
}
Case 'uninstall planning preserves copy and user data' {
    & (Join-Path $project 'scripts/Uninstall.ps1') -ProjectRoot $project -WhatIf
    Assert-True (Test-Path -LiteralPath (Join-Path $project '.local/copy/current.json')) 'Planning removed copy'
}
Case 'uninstall removes only the managed copy and leaves original and profile' {
    if (-not ('UsageSidebar.ShortcutProperties' -as [type])) { Add-Type -Path (Join-Path $project 'scripts/ShortcutProperties.cs') }
    $copy=Read-UsageCopyCurrent $project
    $owned=Join-Path $project 'ChatGPT with Usage.lnk'
    $legacy=Join-Path $project 'Old custom copy name.lnk'
    $foreign=Join-Path $project 'ChatGPT.lnk'
    foreach ($link in @($owned,$legacy)) { [UsageSidebar.ShortcutProperties]::Create($link,(Join-Path $copy.appDir 'ChatGPT.exe'),$copy.appDir) }
    [UsageSidebar.ShortcutProperties]::Create($foreign,(Join-Path $source 'ChatGPT.exe'),$source)
    $foreignBefore=(Get-FileHash -LiteralPath $foreign).Hash
    & (Join-Path $project 'scripts/Uninstall.ps1') -ProjectRoot $project -Confirm:$false
    $remaining=@(Get-ChildItem -LiteralPath (Join-Path $project '.local/copy') -Force | Where-Object Name -NotIn @('start.lock','update.lock','prepare.lock'))
    Assert-True ($remaining.Count -eq 0) 'Copy data was not removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'ChatGPT.exe')) 'Original fixture removed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $settings.codexHome 'keep.txt')) -eq 'profile sentinel') 'Profile removed'
    Assert-True (-not [IO.File]::Exists($owned) -and -not [IO.File]::Exists($legacy)) 'Owned shortcuts were not removed'
    Assert-True ((Get-FileHash -LiteralPath $foreign).Hash -ceq $foreignBefore) 'Original app shortcut was removed or changed'
}
$out=Join-Path $root ('.local/test-results/release-setup-ps'+$PSVersionTable.PSVersion.Major+'.json')
[IO.Directory]::CreateDirectory((Split-Path $out -Parent)) | Out-Null
[IO.File]::WriteAllText($out,(@{results=@($results.ToArray())}|ConvertTo-Json -Depth 8),$utf8)
if(@($results|Where-Object status -eq 'failed').Count){exit 1}
