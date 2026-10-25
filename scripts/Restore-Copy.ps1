[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
Assert-UsageCopyStopped
$base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy')
$lock = [IO.File]::Open((Join-Path $base 'prepare.lock'),'OpenOrCreate','ReadWrite','None')
try {
    if (Test-Path -LiteralPath (Join-Path $base 'activation.json')) { throw 'An interrupted activation needs recovery first. Run Launch.cmd.' }
    $old = Read-UsageCopyCurrent $ProjectRoot 'previous'
    $current = Read-UsageCopyCurrent $ProjectRoot
    if (-not $old -or $old.schemaVersion -ne 2) { throw 'No previous managed version is available. You can still use the original Store app.' }
    Assert-UsageCopyPair $old
    Assert-UsageCopyPair $current
    if (-not $PSCmdlet.ShouldProcess($base,'Restore the previous copy; preserve original app and shared user data')) { return }
    $stage = Join-Path $base 'staging'
    Remove-UsageCopyDirectory $ProjectRoot $stage
    $null = Copy-UsageAppTree $old.buildDir $stage
    $restored = Convert-UsageCopyLocation $old $stage
    Write-AppJson (Join-Path $stage 'copy.json') $restored
    $result = Publish-UsageCopy $ProjectRoot $restored $current
    Write-AppJson (Join-Path $base 'restore-hold.json') ([pscustomobject]@{generation=$result.generation})
    Write-Host 'Previous copy restored. Launch.cmd or your taskbar shortcut will use it. Setup.cmd or Update.cmd releases this hold.'
    $result
} finally { $lock.Dispose() }
