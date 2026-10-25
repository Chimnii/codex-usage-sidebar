[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
Assert-UsageCopyStopped
$base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy')
$startLock = $null
$lock = $null
try {
    $startLock = [IO.File]::Open((Join-Path $base 'start.lock'),'OpenOrCreate','ReadWrite','None')
    $lock = [IO.File]::Open((Join-Path $base 'prepare.lock'),'OpenOrCreate','ReadWrite','None')
    Assert-UsageCopyStopped
    if (Test-Path -LiteralPath (Join-Path $base 'activation.json')) {
        $pending = Read-AppJson (Join-Path $base 'activation.json')
        if (-not $PSCmdlet.ShouldProcess($base,'Recover the interrupted copy activation')) { return }
        Complete-UsageCopyActivation $ProjectRoot
        if ((Get-UsageCopyProperty $pending 'operation') -ceq 'repair') {
            Write-Host 'Interrupted restoration completed. The verified previous backup is preserved.'
            return Read-UsageCopyCurrent $ProjectRoot
        }
    }
    $old = Read-UsageCopyCurrent $ProjectRoot 'previous'
    $current = Read-UsageCopyCurrent $ProjectRoot -AllowMissingSlot
    if (-not $old -or $old.schemaVersion -ne 2) { throw 'No previous managed version is available. You can still use the original Store app.' }
    Assert-UsageCopyPair $old
    $currentValid = $false
    if ($current) { try { Assert-UsageCopyPair $current; $currentValid = $true } catch { } }
    if (-not $PSCmdlet.ShouldProcess($base,'Restore the previous copy; preserve original app and shared user data')) { return }
    $stage = Join-Path $base 'staging'
    Remove-UsageCopyDirectory $ProjectRoot $stage
    $null = Copy-UsageAppTree $old.buildDir $stage
    $restored = Convert-UsageCopyLocation $old $stage
    Write-AppJson (Join-Path $stage 'copy.json') $restored
    $result = if ($currentValid) { Publish-UsageCopy $ProjectRoot $restored $current }
        else { Repair-UsageCopyFromPrevious $ProjectRoot $restored $old }
    Write-AppJson (Join-Path $base 'restore-hold.json') ([pscustomobject]@{generation=$result.generation})
    Write-Host 'Previous copy restored. Launch.cmd or your taskbar shortcut will use it. Setup.cmd or Update.cmd releases this hold.'
    $result
} finally { if ($lock) { $lock.Dispose() }; if ($startLock) { $startLock.Dispose() } }
