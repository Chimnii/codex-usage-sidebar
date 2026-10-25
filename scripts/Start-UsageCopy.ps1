[CmdletBinding()]
param([string]$ProjectRoot, [switch]$CheckOnly, [switch]$Refresh)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$configuration = Get-UsageSettings $ProjectRoot
$profiles = Get-UsageCopyProfiles $configuration.value
$base = Assert-AppPlainPath (Join-Path $configuration.root '.local/copy') -AllowMissing
if ($CheckOnly) {
    $current = Read-UsageCopyCurrent $configuration.root
    if ($current) { Assert-UsageCopyPair $current }
    [pscustomobject]@{ status = 'checked'; profiles = $profiles; copy = $current; runningDesktopProcesses = @(Get-UsageCopyBlockers).Count }
    return
}
[void][IO.Directory]::CreateDirectory($base)
$lock = [IO.File]::Open((Join-Path $base 'start.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    Assert-UsageCopyStopped
    if ([IO.File]::Exists((Join-Path $base 'activation.json'))) {
        # Recover before reading a pointer whose active directory may be in
        # transit. Keep the same start -> prepare lock order as preparation.
        $recoveryLock = [IO.File]::Open((Join-Path $base 'prepare.lock'),'OpenOrCreate','ReadWrite','None')
        try { Complete-UsageCopyActivation $configuration.root }
        finally { $recoveryLock.Dispose() }
    }
    $holdPath = Join-Path $base 'restore-hold.json'
    $selected = Read-UsageCopyCurrent $configuration.root
    $held = $false
    if (-not $Refresh -and $selected -and [IO.File]::Exists($holdPath)) {
        $held = (Read-AppJson $holdPath).generation -ceq $selected.generation
    }
    $prepared = if ($held) { [pscustomobject]@{copy=$selected} } else { & (Join-Path $PSScriptRoot 'Prepare-UsageCopy.ps1') -ProjectRoot $configuration.root -Confirm:$false }
    if (-not $held -and [IO.File]::Exists($holdPath)) { Remove-Item -LiteralPath $holdPath }
    $copy = $prepared.copy
    Assert-UsageCopyStopped
    Assert-UsageCopyPair $copy
    $launchId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $launches = Join-Path $base 'launches'
    [void][IO.Directory]::CreateDirectory($launches)
    $launchPath = Join-Path $launches ($launchId + '.json')
    $launch = [pscustomobject]@{
        schemaVersion = 1; launchId = $launchId; startedAt = [DateTime]::UtcNow.ToString('o')
        appDir = $copy.appDir; layerRoot = $copy.layerRoot; profiles = $profiles
        packageFullName = $copy.packageFullName; pid = $null; verification = 'pending'
    }
    Write-AppJson $launchPath $launch -CreateNew
    $start = New-UsageCopyStartInfo $copy $configuration.value $launchId
    $process = [Diagnostics.Process]::Start($start)
    $launch.pid = $process.Id
    Write-AppJson $launchPath $launch
    Write-AppJson (Join-Path $base 'last-launch.json') ([pscustomobject]@{ launchId = $launchId; launchPath = $launchPath })
    # This independent helper survives closing the launcher. No CDP port or
    # browser-profile override is needed to collect the small health report.
    $helper = Join-Path $PSScriptRoot 'Watch-UsageCopy.ps1'
    $shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    Start-Process -FilePath $shell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $helper + '"'), '-LaunchPath', ('"' + $launchPath + '"')) -WindowStyle Hidden | Out-Null
    Write-Host 'Started the copy with the original user data. Usage and UI checks will be recorded automatically.'
    Write-Host "Launch report: $launchPath"
}
catch {
    Write-AppJson (Join-Path $base 'last-start-error.json') ([pscustomobject]@{ at = [DateTime]::UtcNow.ToString('o'); error = $_.Exception.Message; location = $_.ScriptStackTrace })
    throw
}
finally { $lock.Dispose() }
