Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root ('.local/tests/update-entry-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'scripts'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'patcher'))
[void][IO.Directory]::CreateDirectory((Join-Path $fixture '.local/copy'))
$utf8=New-Object Text.UTF8Encoding($false)
function Write-File { param($Path,$Text); [IO.File]::WriteAllText((Join-Path $fixture $Path),$Text,$utf8) }
foreach($name in @('Update-UsageCopy.ps1','UsageUpdate.Common.psm1')) { Copy-Item -LiteralPath (Join-Path $root "scripts/$name") -Destination (Join-Path $fixture "scripts/$name") }
Write-File 'scripts/Environment.Common.psm1' @'
function Get-UsageSettings { param($ProjectRoot); return [pscustomobject]@{root=$ProjectRoot} }
function Get-UsageTarget { param($Configuration); $s=Get-Content -Encoding UTF8 (Join-Path $Configuration.root 'fixture.json') -Raw|ConvertFrom-Json; return [pscustomobject]@{packageFullName=('OpenAI.Codex_'+$s.version+'_x64__2p2nqsd0c76g0')} }
'@
Write-File 'scripts/UsageCopy.Common.psm1' @'
function Get-UsageCopyBlockers { $s=Get-Content -Encoding UTF8 (Join-Path (Split-Path $PSScriptRoot -Parent) 'fixture.json') -Raw|ConvertFrom-Json; if($s.running){return @([pscustomobject]@{ProcessId=123})};return @() }
function Assert-UsageCopyStopped { if(@(Get-UsageCopyBlockers).Count){throw 'Fixture app is running'} }
function Read-UsageCopyCurrent { param($ProjectRoot); $s=Get-Content -Encoding UTF8 (Join-Path $ProjectRoot 'fixture.json') -Raw|ConvertFrom-Json; return [pscustomobject]@{packageFullName=('OpenAI.Codex_'+$s.copyVersion+'_x64__2p2nqsd0c76g0')} }
'@
Write-File 'patcher/AppPatch.Common.psm1' @'
function Write-AppJson { param($Path,$Value);[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8)) }
'@
Write-File 'scripts/Start-UsageCopy.ps1' @'
param($ProjectRoot, [switch]$Refresh)
$marker=Get-Content -Encoding UTF8 (Join-Path $ProjectRoot '.local/copy/update-in-progress.json') -Raw|ConvertFrom-Json
if($env:SIDEBAR_USAGE_UPDATE_OWNER -cne $marker.ownerToken){throw 'Updater launch did not own the marker'}
[IO.File]::AppendAllText((Join-Path $ProjectRoot 'calls.txt'),"launch`n")
'@
$mock=@'

function Invoke-UsageStoreCommand {
  param($Action,$TimeoutSeconds)
  $root=Split-Path $PSScriptRoot -Parent
  [IO.File]::AppendAllText((Join-Path $root 'calls.txt'),($Action+"`n"))
  $p=Join-Path $root 'fixture.json';$s=Get-Content -Encoding UTF8 $p -Raw|ConvertFrom-Json
  if($s.offline){throw 'Fixture Store offline'}
  $b=[char]0x2502
  $table="$b Name $b Publisher $b Version $b`n$b ChatGPT $b OpenAI $b $($s.version) $b"
  if($Action -eq 'installed'){return $table}
  if($Action -eq 'updates'){if($s.pending){return $table};return 'No updates found.'}
  if($Action -eq 'apply'){
    if($s.failApply){throw 'Fixture installation failed'}
    $s.version='26.1017.1.0';$s.pending=$false;[IO.File]::WriteAllText($p,($s|ConvertTo-Json));return 'Updated'
  }
  throw 'Unexpected action'
}
Export-ModuleMember -Function *-UsageStore*, Invoke-UsageUpdateFlow
'@
[IO.File]::AppendAllText((Join-Path $fixture 'scripts/UsageUpdate.Common.psm1'),$mock,$utf8)
$results=New-Object 'Collections.Generic.List[object]'
function Assert-True {param($Value,$Message);if(-not $Value){throw $Message}}
function Reset-Fixture {param($Pending=$false,$Running=$false,$Fail=$false,$Offline=$false,$CopyVersion='26.1016.8120.0');Write-File 'fixture.json' (@{version='26.1016.8120.0';copyVersion=$CopyVersion;pending=$Pending;running=$Running;failApply=$Fail;offline=$Offline}|ConvertTo-Json);Write-File 'calls.txt' ''}
function Run-Entry {
    param([string[]]$Arguments=@())
    $shell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $savedPreference=$ErrorActionPreference
    try {
        # A failing child is expected in negative tests; collect its stderr and
        # exit status instead of converting NativeCommandError into a test error.
        $ErrorActionPreference='Continue'
        $output=& $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts/Update-UsageCopy.ps1') -ProjectRoot $fixture @Arguments 2>&1
        $code=$LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
    return @{code=$code;output=($output -join "`n");calls=[IO.File]::ReadAllText((Join-Path $fixture 'calls.txt'))}
}
function Case {param($Name,[scriptblock]$Action);try{&$Action;$results.Add(@{name=$Name;status='passed'});Write-Host "PASS $Name"}catch{$results.Add(@{name=$Name;status='failed';error=$_.Exception.Message;location=$_.ScriptStackTrace});Write-Host "FAIL $Name : $($_.Exception.Message)"}}
Case 'actual entry point no-update path checks then launches' {Reset-Fixture;$r=Run-Entry;Assert-True ($r.code -eq 0 -and $r.calls -eq "installed`nupdates`nlaunch`n") $r.output}
Case 'actual entry point update path installs, verifies new version, then launches' {Reset-Fixture $true;$r=Run-Entry;Assert-True ($r.code -eq 0 -and $r.calls -eq "installed`nupdates`napply`ninstalled`nupdates`nlaunch`n") $r.output}
Case 'installation failure produces diagnostic and no launch' {Reset-Fixture $true $false $true;$r=Run-Entry;Assert-True ($r.code -ne 0 -and $r.calls -notmatch 'launch') 'Launched on failed install';Assert-True (Test-Path (Join-Path $fixture '.local/copy/last-update-error.json')) 'Missing diagnostic'}
Case 'active desktop blocks Store calls before any update' {Reset-Fixture $true $true;$r=Run-Entry;Assert-True ($r.code -ne 0 -and $r.calls -eq '') 'Store was called with running app'}
Case 'wait-for-exit times out without querying, installing or stopping app' {Reset-Fixture $true $true;$r=Run-Entry @('-WaitForExit','-WaitTimeoutSeconds','1');Assert-True ($r.code -ne 0 -and $r.calls -eq '') 'Wait guard failed';$s=Get-Content -Encoding UTF8 (Join-Path $fixture 'fixture.json') -Raw|ConvertFrom-Json;Assert-True $s.running 'App was stopped'}
Case 'check-only can run while app is open and never starts installer' {Reset-Fixture $true $true;$r=Run-Entry @('-CheckOnly','-Json');Assert-True ($r.code -eq 0 -and $r.calls -eq "installed`nupdates`n") $r.output;Assert-True (($r.output|ConvertFrom-Json).status -eq 'available') 'Wrong check result'}
Case 'WhatIf never checks, installs or launches' {Reset-Fixture $true;$r=Run-Entry @('-WhatIf');Assert-True ($r.code -eq 0 -and $r.calls -eq '') $r.output}
Case 'another launcher lock prevents the updater from starting' {Reset-Fixture $true;$lock=[IO.File]::Open((Join-Path $fixture '.local/copy/start.lock'),'OpenOrCreate','ReadWrite','None');try{$r=Run-Entry;Assert-True ($r.code -ne 0 -and $r.calls -eq '') 'Lock did not prevent update'}finally{$lock.Dispose()}}
Case 'offline newer local original launches without applying Store updates' {Reset-Fixture -Offline $true -CopyVersion '26.1015.1.0';$r=Run-Entry;Assert-True ($r.code -eq 0 -and $r.calls -eq "installed`nlaunch`n") $r.output}
Case 'offline equal local original does not claim current or launch' {Reset-Fixture -Offline $true;$r=Run-Entry;Assert-True ($r.code -ne 0 -and $r.calls -eq "installed`n") 'Unknown Store state launched'}
Case 'local-only check never invokes Store and reports a newer original' {Reset-Fixture -Offline $true;$r=Run-Entry @('-CheckOnly','-Json','-LocalOnly','-RunningPackageFullName','OpenAI.Codex_26.1015.1.0_x64__2p2nqsd0c76g0');Assert-True ($r.code -eq 0 -and $r.calls -eq '') $r.output;$s=$r.output|ConvertFrom-Json;Assert-True ($s.copyUpdateRequired -and $s.storeStatus -eq 'unchecked') 'Local-only check lost copy evidence'}
Case 'another updater owns its marker until its lock is released' {
    Reset-Fixture
    $marker=Join-Path $fixture '.local/copy/update-in-progress.json'
    [IO.File]::WriteAllText($marker,'existing owner')
    $lock=[IO.File]::Open((Join-Path $fixture '.local/copy/update.lock'),'OpenOrCreate','ReadWrite','None')
    try {$r=Run-Entry;Assert-True ($r.code -ne 0 -and $r.calls -eq '') 'Concurrent updater ran';Assert-True ([IO.File]::ReadAllText($marker) -ceq 'existing owner') 'Another owner marker was removed'} finally {$lock.Dispose()}
    $r=Run-Entry;Assert-True ($r.code -eq 0) $r.output;Assert-True ([IO.File]::ReadAllText($marker) -cne 'existing owner') 'Stale marker was not replaced'
}
Case 'bootstrap checks actual Windows lock ownership and ignores the completed marker' {
    Reset-Fixture;$r=Run-Entry;Assert-True ($r.code -eq 0) $r.output
    $probe=Join-Path $fixture 'guard-probe.cjs'
    $bootstrap=(Join-Path $root 'patcher/repatch/copy-bootstrap.cjs')|ConvertTo-Json -Compress
    [IO.File]::WriteAllText($probe,("const {updateInProgress}=require("+$bootstrap+"); process.stdout.write(String(updateInProgress(process.argv[2])));"),$utf8)
    $lock=[IO.File]::Open((Join-Path $fixture '.local/copy/update.lock'),'OpenOrCreate','ReadWrite','None')
    try {$active=& node $probe $fixture;Assert-True ($LASTEXITCODE -eq 0 -and $active -ceq 'true') 'Live Windows lock was not detected'} finally {$lock.Dispose()}
    $inactive=& node $probe $fixture;Assert-True ($LASTEXITCODE -eq 0 -and $inactive -ceq 'false') 'Completed marker blocked launch'
}
$report=@{checkedAt=[DateTime]::UtcNow.ToString('o');fixture=$fixture;results=@($results.ToArray())}
[IO.File]::WriteAllText((Join-Path $root '.local/test-results/update-entry-ps5.json'),($report|ConvertTo-Json -Depth 8),$utf8)
if(@($results|Where-Object{$_.status -eq 'failed'}).Count){exit 1}
