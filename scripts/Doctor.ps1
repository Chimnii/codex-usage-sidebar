[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot), [switch]$Json)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'patcher/AppPatch.Common.psm1') -DisableNameChecking

# This command only reads local metadata and hashes the two managed app files.
# It never queries Store, starts a collector, reads credentials or writes a file.
function Read-DiagnosticJson([string]$Path) {
    try {
        $file = Get-Item -LiteralPath (Assert-AppPlainPath $Path)
        if ($file.Length -gt 1MB) { return $null }
        return Read-AppJson $file.FullName
    } catch { return $null }
}
function Get-SafeVersion($Value) {
    if ([string]$Value -match '^\d+\.\d+\.\d+(?:\.\d+)?(?:-[a-zA-Z0-9.-]+)?$') { return [string]$Value }
    return $null
}
function Get-PackageVersion($Value) {
    if ([string]$Value -match '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$') { return $Matches[1] }
    return $null
}
function Get-SafeTime($Value) {
    if ($Value -isnot [string]) { return $null }
    try { return ([DateTimeOffset]::Parse($Value)).ToUniversalTime().ToString('o') } catch { return $null }
}
function Get-SafeCount($Value) {
    if (($Value -is [int] -or $Value -is [long] -or $Value -is [double]) -and $Value -ge 0 -and $Value -le 100000000) { return $Value }
    return $null
}

$project = Get-AppDirectory $ProjectRoot
$base = Join-Path $project '.local/copy'
$source = Read-DiagnosticJson (Join-Path $project 'package.json')
$report = [ordered]@{
    schemaVersion=1; checkedAt=[DateTime]::UtcNow.ToString('o')
    sourceVersion=(Get-SafeVersion (Get-UsageCopyProperty $source 'version'))
    setup='unavailable'; installedVersion=$null; copyVersion=$null; localUpdateRequired=$null
    copyIntegrity='not-prepared'; rollbackIntegrity='not-prepared'; repairAvailable=$false
    interruptedActivation=[IO.File]::Exists((Join-Path $base 'activation.json'))
    restoreHold=[IO.File]::Exists((Join-Path $base 'restore-hold.json'))
    damagedSlotRetained=[IO.Directory]::Exists((Join-Path $base 'damaged'))
    runningCopy=$null; sharedProfilesMatch=$null
    tweakVersion=$null; layerVersion=$null; bridge=$null; providers=@(); update=$null
}
$settings = $null
try { $settings = (Get-UsageSettings $project).value; $report.setup='ready' } catch { }
try {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $appxCommand = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue
        if (-not $appxCommand -or $appxCommand.ModuleName -eq 'Appx') {
            Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop
        }
    }
    $installed = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Where-Object PackageFamilyName -CEQ 'OpenAI.Codex_2p2nqsd0c76g0')
    if ($installed.Count -eq 1) { $report.installedVersion = Get-PackageVersion $installed[0].PackageFullName }
} catch { }
$current = $null
foreach ($slot in @('current','previous')) {
    $key = if ($slot -eq 'current') { 'copyIntegrity' } else { 'rollbackIntegrity' }
    try {
        $copy = Read-UsageCopyCurrent $project $slot -AllowMissingSlot
        if (-not $copy) { continue }
        if ($slot -eq 'current') { $current = $copy; $report.copyVersion = Get-PackageVersion $copy.packageFullName }
        if (-not [IO.Directory]::Exists($copy.appDir)) { $report[$key]='missing'; continue }
        Assert-UsageCopyPair $copy
        $report[$key]='verified'
    } catch { $report[$key]='invalid' }
}
$report.repairAvailable = $settings -and $null -ne $report.installedVersion
$report.repairMethod = 'rebuild-from-installed-app'
if ($report.installedVersion -and $report.copyVersion) { $report.localUpdateRequired = $report.installedVersion -ne $report.copyVersion }
if ($current) {
    try { $report.runningCopy = @(Get-UsageCopyBlockers | Where-Object ExecutablePath -IEQ (Join-Path $current.appDir 'ChatGPT.exe')).Count -gt 0 } catch { }
    if ($settings) {
        $profiles = Get-UsageCopyProperty $current 'profiles'
        $report.sharedProfilesMatch = (Get-UsageCopyProperty $profiles 'codexHome') -ieq $settings.codexHome -and
            (Get-UsageCopyProperty $profiles 'electronUserData') -ieq (Join-Path $settings.appData 'Codex') -and
            (Get-UsageCopyProperty $profiles 'webProfile') -ieq (Join-Path $settings.appData 'Codex/web/Codex')
    }
    $data = Join-Path $current.layerRoot 'tweak-data/local.sidebar-usage-demo'
    $manifest = Read-DiagnosticJson (Join-Path $current.layerRoot 'tweaks/local.sidebar-usage-demo/manifest.json')
    $report.tweakVersion = Get-SafeVersion (Get-UsageCopyProperty $manifest 'version')
    $layer = Read-DiagnosticJson (Join-Path $project '.local/layer-source/package.json')
    $report.layerVersion = Get-SafeVersion (Get-UsageCopyProperty $layer 'version')
    $bridge = Read-DiagnosticJson (Join-Path $data 'bridge-status.json')
    $config = Read-DiagnosticJson (Join-Path $data 'collector-config.json')
    $cache = Read-DiagnosticJson (Join-Path $data 'usage-cache.json')
    if ($bridge) {
        $ui = Get-UsageCopyProperty $bridge 'ui'
        $reportedAt = Get-SafeTime (Get-UsageCopyProperty $ui 'reportedAt')
        $menu = Get-UsageCopyProperty $bridge 'updateMenuHealth'
        $menuState = Get-UsageCopyProperty $menu 'status' 'unknown'
        if ($menuState -notin @('ok','unsupported','unavailable','pending','stopped')) { $menuState='unknown' }
        $report.bridge = [ordered]@{
            updatedAt=(Get-SafeTime (Get-UsageCopyProperty $bridge 'updatedAt'))
            cycles=(Get-SafeCount (Get-UsageCopyProperty $bridge 'cycles'))
            intervalMs=(Get-SafeCount (Get-UsageCopyProperty $bridge 'intervalMs'))
            collectorActive=((Get-UsageCopyProperty $bridge 'active') -eq $true)
            durationMs=(Get-SafeCount (Get-UsageCopyProperty $bridge 'durationMs'))
            updateMenuEntries=(Get-SafeCount (Get-UsageCopyProperty $bridge 'updateMenuEntries'))
            updateMenuStatus=$menuState
            uiReportedAt=$reportedAt
            visiblePanels=(Get-SafeCount (Get-UsageCopyProperty $ui 'visiblePanels'))
            hiddenBySettings=((Get-UsageCopyProperty $ui 'hiddenBySettings') -eq $true)
            withinSidebar=((Get-UsageCopyProperty $ui 'withinSidebar') -eq $true)
            snagDetected=((Get-UsageCopyProperty $ui 'snagDetected') -eq $true)
        }
    }
    $report.providers = @(foreach ($id in @('codex','antigravity','claude')) {
        $rows = @(Get-UsageCopyProperty $bridge 'providers' @() | Where-Object id -CEQ $id | Select-Object -First 1)
        if (-not $rows.Count) { $rows = @(Get-UsageCopyProperty $cache 'providers' @() | Where-Object id -CEQ $id | Select-Object -First 1) }
        $provider = if ($rows.Count) { $rows[0] } else { $null }
        $enabled = switch ($id) { 'antigravity' { [bool](Get-UsageCopyProperty $config 'agyPath') }; 'claude' { [bool](Get-UsageCopyProperty $config 'claudeCredentialsPath') }; default { $true } }
        $hints = Get-UsageCopyProperty $config 'providerEnabled'
        if ($hints -and $hints.PSObject.Properties[$id] -and $hints.$id -is [bool]) { $enabled = $hints.$id }
        $state = Get-UsageCopyProperty $provider 'status' 'unknown'
        if ($state -notin @('ok','stale','unavailable','disconnected')) { $state = 'unknown' }
        if (-not $enabled) { $state='disabled' }
        $code = Get-UsageCopyProperty $provider 'errorCode'
        if ($code -notin @('CONFIG_ERROR','MISSING_EXECUTABLE','START_FAILED','TIMEOUT','BAD_RESPONSE','RPC_ERROR','EXIT_FAILURE','OUTPUT_LIMIT','ABORTED','CLAUDE_NOT_CONNECTED','CLAUDE_AUTH_REQUIRED','RATE_LIMITED')) { $code=$null }
        [ordered]@{ id=$id; enabled=[bool]$enabled; status=$state; errorCode=$code
            checkedAt=(Get-SafeTime (Get-UsageCopyProperty $provider 'checkedAt'))
            attemptedAt=(Get-SafeTime (Get-UsageCopyProperty $provider 'attemptedAt'))
            nextAttemptAt=(Get-SafeTime (Get-UsageCopyProperty $provider 'nextAttemptAt')) }
    })
    $update = Read-DiagnosticJson (Join-Path $data 'update-status.json')
    if ($update) {
        $state = Get-UsageCopyProperty $update 'status'
        if ($state -notin @('current','available','unknown','error')) { $state='unknown' }
        $storeState = Get-UsageCopyProperty $update 'storeStatus' 'unknown'
        if ($storeState -notin @('current','available','error','unchecked')) { $storeState='unknown' }
        $storeError = Get-UsageCopyProperty $update 'storeError'
        if ($storeError -notin @('metadata-pending','query-failed')) { $storeError=$null }
        $report.update = [ordered]@{ status=$state; checkedAt=(Get-SafeTime (Get-UsageCopyProperty $update 'checkedAt'))
            storeUpdateAvailable=((Get-UsageCopyProperty $update 'storeUpdateAvailable') -eq $true)
            copyUpdateRequired=((Get-UsageCopyProperty $update 'copyUpdateRequired') -eq $true)
            storeStatus=$storeState; storeCheckedAt=(Get-SafeTime (Get-UsageCopyProperty $update 'storeCheckedAt')); storeError=$storeError }
    }
}
if ($Json) { $report | ConvertTo-Json -Depth 8; return }
Write-Output 'Codex Usage Sidebar - local diagnostics (no Store query)'
Write-Output ('Source: {0}; installed app: {1}; copy: {2}' -f $report.sourceVersion,$report.installedVersion,$report.copyVersion)
Write-Output ('Setup: {0}; copy integrity: {1}; rollback integrity: {2}' -f $report.setup,$report.copyIntegrity,$report.rollbackIntegrity)
Write-Output ('Running copy: {0}; shared profiles match: {1}; local update needed: {2}' -f $report.runningCopy,$report.sharedProfilesMatch,$report.localUpdateRequired)
Write-Output ('Interrupted activation: {0}; restored version held: {1}; damaged slot retained: {2}' -f $report.interruptedActivation,$report.restoreHold,$report.damagedSlotRetained)
if ($report.bridge) { Write-Output ('UI panels: {0}; UI last report: {1}; collector cycles: {2}; update menu entries: {3}' -f $report.bridge.visiblePanels,$report.bridge.uiReportedAt,$report.bridge.cycles,$report.bridge.updateMenuEntries) }
foreach ($provider in $report.providers) { Write-Output ('{0}: {1}; last success: {2}; error: {3}' -f $provider.id,$provider.status,$provider.checkedAt,$provider.errorCode) }
if ($report.update) { Write-Output ('Cached update state: {0}; checked: {1}' -f $report.update.status,$report.update.checkedAt) }
Write-Output 'Use Doctor.cmd -Json for shareable structured output. No paths, credentials or conversation contents are included.'
