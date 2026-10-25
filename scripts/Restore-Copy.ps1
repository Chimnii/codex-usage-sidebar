[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
Assert-UsageCopyStopped
$base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy') -AllowMissing
if (-not $PSCmdlet.ShouldProcess($base,'Rebuild the app copy from the installed original; preserve conversations and settings')) { return }
[void][IO.Directory]::CreateDirectory($base)
$lock = [IO.File]::Open((Join-Path $base 'start.lock'),'OpenOrCreate','ReadWrite','None')
try {
    Assert-UsageCopyStopped
    $result = & (Join-Path $PSScriptRoot 'Prepare-UsageCopy.ps1') -ProjectRoot $ProjectRoot -ForceRebuild -Confirm:$false
    $hold = Join-Path $base 'restore-hold.json'
    if ([IO.File]::Exists($hold)) { [IO.File]::Delete($hold) }
    & (Join-Path $PSScriptRoot 'Install-UsageShortcut.ps1') -ProjectRoot $ProjectRoot -UpdateExistingPin | Out-Host
    Write-Host 'App copy rebuilt from the installed original. Open ChatGPT with usage from your shortcut.'
    return $result.copy
} finally { $lock.Dispose() }
