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
Case 'uninstall planning preserves copy and user data' {
    & (Join-Path $project 'scripts/Uninstall.ps1') -ProjectRoot $project -WhatIf
    Assert-True (Test-Path -LiteralPath (Join-Path $project '.local/copy/current.json')) 'Planning removed copy'
}
Case 'uninstall removes only the managed copy and leaves original and profile' {
    & (Join-Path $project 'scripts/Uninstall.ps1') -ProjectRoot $project -Confirm:$false
    $remaining=@(Get-ChildItem -LiteralPath (Join-Path $project '.local/copy') -Force | Where-Object Name -NotIn @('start.lock','update.lock','prepare.lock'))
    Assert-True ($remaining.Count -eq 0) 'Copy data was not removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $source 'ChatGPT.exe')) 'Original fixture removed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $settings.codexHome 'keep.txt')) -eq 'profile sentinel') 'Profile removed'
}
$out=Join-Path $root ('.local/test-results/release-setup-ps'+$PSVersionTable.PSVersion.Major+'.json')
[IO.Directory]::CreateDirectory((Split-Path $out -Parent)) | Out-Null
[IO.File]::WriteAllText($out,(@{results=@($results.ToArray())}|ConvertTo-Json -Depth 8),$utf8)
if(@($results|Where-Object status -eq 'failed').Count){exit 1}
