Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'scripts/UsageUpdate.Common.psm1') -Force -DisableNameChecking
$results = New-Object 'Collections.Generic.List[object]'
function Assert-True { param($Condition,$Message); if (-not $Condition) { throw $Message } }
function Expect-Failure { param([scriptblock]$Action); try { & $Action | Out-Null } catch { return $_.Exception.Message }; throw 'Expected failure.' }
function Case { param($Name,[scriptblock]$Action); try { & $Action; $results.Add(@{name=$Name;status='passed'}); Write-Host "PASS $Name" } catch { $results.Add(@{name=$Name;status='failed';error=$_.Exception.Message;location=$_.ScriptStackTrace}); Write-Host "FAIL $Name : $($_.Exception.Message)" } }
function Table { param($Name='ChatGPT',$Publisher='OpenAI'); $bar=[char]0x2502; return "$bar Name $bar Publisher $bar Version $bar`n$bar $Name $bar $Publisher $bar 26.1016.8120.0 $bar" }
Case 'recognize no updates, exact target, and ignore Classic/Beta/other publishers' {
    Assert-True (-not (ConvertFrom-UsageStoreUpdates "Checking for updates...`nNo updates found.")) 'No-update result failed.'
    Assert-True (ConvertFrom-UsageStoreUpdates (Table)) 'Target missing.'
    foreach ($name in @('ChatGPT Classic','ChatGPT (Beta)','ChatGPT Pro')) { Assert-True (-not (ConvertFrom-UsageStoreUpdates (Table $name))) 'Matched another app.' }
    Assert-True (-not (ConvertFrom-UsageStoreUpdates (Table ChatGPT Unknown))) 'Matched wrong publisher.'
}
Case 'failed or changed output never becomes no-update success' {
    foreach ($text in @('Error: network unavailable','Checking for updates...', 'Completely different output', "Error: service failed`nNo updates found.")) {
        $null = Expect-Failure { ConvertFrom-UsageStoreUpdates $text }
    }
}
function Flow {
    param($Scenario)
    $bag = @{ scenario=$Scenario; version='26.1016.8120.0'; calls=(New-Object 'Collections.Generic.List[string]'); checks=0; guards=0 }
    $get = { $bag.calls.Add('target'); [pscustomobject]@{packageFullName=('OpenAI.Codex_'+$bag.version+'_x64__2p2nqsd0c76g0')} }.GetNewClosure()
    $check = { param($target); $bag.calls.Add('check'); $bag.checks++; if ($bag.scenario -eq 'query-fails') { throw 'offline' }; $available=$bag.scenario -ne 'none' -and $bag.version -eq '26.1016.8120.0'; [pscustomobject]@{status=$(if($available){'available'}else{'current'});storeUpdateAvailable=$available} }.GetNewClosure()
    $apply = { $bag.calls.Add('apply'); if ($bag.scenario -eq 'apply-fails') { throw 'Store failed' }; if ($bag.scenario -eq 'updated') { $bag.version='26.1017.1.0' } }.GetNewClosure()
    $guard = { $bag.guards++; $bag.calls.Add('guard'); if ($bag.scenario -eq 'running' -or ($bag.scenario -eq 'opened-later' -and $bag.guards -gt 1)) { throw 'App is running' } }.GetNewClosure()
    $launch = { $bag.calls.Add('launch') }.GetNewClosure()
    $delay = { $bag.calls.Add('delay') }.GetNewClosure()
    try { Invoke-UsageUpdateFlow -GetTarget $get -Check $check -Apply $apply -Guard $guard -Launch $launch -Delay $delay -Log {} -CompletionAttempts 2 }
    catch { $bag.error=$_.Exception.Message }
    return $bag
}
Case 'no update launches the copy without installing' {
    $bag=Flow none
    Assert-True (-not $bag.ContainsKey('error')) 'Unexpected flow error.'
    Assert-True ($bag.calls -contains 'launch' -and $bag.calls -notcontains 'apply') 'Wrong no-update path.'
}
Case 'available update requires newer installed version and second check before launch' {
    $bag=Flow updated
    Assert-True (-not $bag.ContainsKey('error')) 'Update failed.'
    Assert-True ($bag.checks -eq 2 -and $bag.calls -contains 'apply' -and $bag.calls[$bag.calls.Count-1] -eq 'launch') 'Did not verify installation before launch.'
}
Case 'queued or falsely successful install without new version cannot launch' {
    $bag=Flow unchanged
    Assert-True ($bag.ContainsKey('error') -and $bag.calls -notcontains 'launch') 'Launched without installation evidence.'
}
Case 'query and install errors preserve existing copy and stop before launch' {
    foreach ($scenario in @('query-fails','apply-fails')) {
        $bag=Flow $scenario
        Assert-True ($bag.ContainsKey('error') -and $bag.calls -notcontains 'launch') 'Launched on failure.'
        if ($scenario -eq 'query-fails') { Assert-True ($bag.calls -notcontains 'apply') 'Installed despite query failure.' }
    }
}
Case 'running app blocks queries and installation without stopping processes' {
    $bag=Flow running
    Assert-True ($bag.ContainsKey('error') -and $bag.calls.Count -eq 1 -and $bag.calls[0] -eq 'guard') 'Running app guard was late.'
    $bag=Flow opened-later
    Assert-True ($bag.ContainsKey('error') -and $bag.calls -notcontains 'apply') 'Did not recheck before install.'
}
Case 'background status detects original auto-update even when Store has no pending update' {
    $module = Get-Module UsageUpdate.Common
    $table=Table
    & $module { param($t); $script:testTable=$t; function script:Invoke-UsageStoreCommand { param($Action); if($Action -eq 'installed'){return $script:testTable}; if($Action -eq 'updates'){return 'No updates found.'}; throw 'Background check requested installation' } } $table
    $target=[pscustomobject]@{packageFullName='OpenAI.Codex_26.1016.8120.0_x64__2p2nqsd0c76g0'}
    $status=Get-UsageStoreStatus $target 'OpenAI.Codex_26.1015.1.0_x64__2p2nqsd0c76g0'
    Assert-True ($status.status -eq 'available' -and $status.copyUpdateRequired -and -not $status.storeUpdateAvailable) 'Missing copy refresh notification.'
    $target.packageFullName='OpenAI.Codex_26.1017.1.0_x64__2p2nqsd0c76g0'
    $null=Expect-Failure { Get-UsageStoreStatus $target }
}
Import-Module (Join-Path $root 'scripts/UsageUpdate.Common.psm1') -Force -DisableNameChecking
$report = @{checkedAt=[DateTime]::UtcNow.ToString('o');results=@($results.ToArray())}
$path=Join-Path $root '.local/test-results/usage-update-ps5.json'
[IO.File]::WriteAllText($path,($report|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
if (@($results | Where-Object {$_.status -eq 'failed'}).Count) { exit 1 }
