[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ProjectRoot, [switch]$CheckOnly, [switch]$Json, [switch]$LocalOnly,
    [string]$RunningPackageFullName, [switch]$WaitForExit,
    [ValidateRange(1,86400)][int]$WaitTimeoutSeconds = 3600
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
$configuration = Get-UsageSettings $ProjectRoot
Import-Module (Join-Path $PSScriptRoot 'UsageUpdate.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
if ($CheckOnly) {
    try { $status = Get-UsageStoreStatus (Get-UsageTarget $configuration) $RunningPackageFullName -LocalOnly:$LocalOnly }
    catch { $status = [pscustomobject]@{ schemaVersion=1; status='error'; checkedAt=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message } }
    if ($Json) { $status | ConvertTo-Json -Compress } else { $status }
    return
}
if ($Json) { throw '-Json requires -CheckOnly.' }
if ($LocalOnly) { throw '-LocalOnly requires -CheckOnly.' }
if (-not $PSCmdlet.ShouldProcess('Microsoft Store and the managed app copy', 'Check for updates, update only ChatGPT if available, verify completion, repatch and launch the copy')) { return }
$base = Join-Path $configuration.root '.local/copy'
[void][IO.Directory]::CreateDirectory($base)
$updateLock = $null; $startLock = $null
$markerPath = Join-Path $base 'update-in-progress.json'
$ownerToken = [guid]::NewGuid().ToString('N')
try {
    $updateLock = [IO.File]::Open((Join-Path $base 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $startLock = [IO.File]::Open((Join-Path $base 'start.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    # Direct taskbar EXE launches see this marker before touching profiles. The
    # exclusive update.lock proves ownership; a crash releases it automatically.
    Write-AppJson $markerPath ([pscustomobject]@{
        schemaVersion=1; pid=$PID; ownerToken=$ownerToken; startedAt=[DateTime]::UtcNow.ToString('o')
        expiresAt=[DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds + 3600).ToString('o')
    })
    if ($WaitForExit) {
        Write-Host 'Update is waiting. Finish your work and fully quit ChatGPT / Codex. No process will be stopped.'
        Write-Host 'Close this helper window to cancel before the update begins.'
        $deadline = [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
        while (@(Get-UsageCopyBlockers).Count) {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the app to close. No Store update was requested.' }
            Start-Sleep -Seconds 2
        }
    }
    $current = Read-UsageCopyCurrent $configuration.root
    $copyPackage = if ($current) { [string]$current.packageFullName } else { '' }
    $getTarget = { Get-UsageTarget $configuration }
    $check = { param($target) Get-UsageStoreStatus $target $copyPackage }
    $apply = { $text = Invoke-UsageStoreCommand apply -TimeoutSeconds 900; Write-Host $text.Trim() }
    $guard = { Assert-UsageCopyStopped }
    # The launcher takes its own start lock after the Store phase is complete.
    $launch = {
        $startLock.Dispose()
        # Only the updater's child may start while the update marker is owned.
        # The bootstrap consumes this token before Layer/the original app load.
        $savedToken = $env:SIDEBAR_USAGE_UPDATE_OWNER
        try {
            $env:SIDEBAR_USAGE_UPDATE_OWNER = $ownerToken
            & (Join-Path $PSScriptRoot 'Start-UsageCopy.ps1') -ProjectRoot $configuration.root -Refresh
        } finally { $env:SIDEBAR_USAGE_UPDATE_OWNER = $savedToken }
    }
    Invoke-UsageUpdateFlow -GetTarget $getTarget -Check $check -Apply $apply -Guard $guard -Launch $launch
}
catch {
    Write-AppJson (Join-Path $base 'last-update-error.json') ([pscustomobject]@{ at=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message; location=$_.ScriptStackTrace })
    throw
}
finally {
    # Keep one last marker. Once this OS lock closes it is inert; retaining it
    # avoids a race with the child reading startup settings while we finish.
    if ($startLock) { $startLock.Dispose() }
    if ($updateLock) { $updateLock.Dispose() }
}
