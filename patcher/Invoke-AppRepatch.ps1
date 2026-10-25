[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$LayerRoot,
    [Parameter(Mandatory = $true)][string]$LayerSourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [Parameter(Mandatory = $true)][string]$BackupRoot,
    [string]$NodePath = 'node',
    [string]$AsarModule,
    [switch]$PortableCopy
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppPatch.Common.psm1') -Force -DisableNameChecking

$original = Get-AppDirectory $AppDir
$runtime = Get-AppDirectory $LayerRoot
$layerSource = Get-AppDirectory $LayerSourceRoot
$output = Assert-AppPlainPath $OutputDir -AllowMissing
$backupRootPath = Assert-AppPlainPath $BackupRoot -AllowMissing
foreach ($inputPath in @($original, $runtime, $layerSource, $output)) {
    Assert-AppSeparatePaths $backupRootPath $inputPath
}
Assert-AppNotRunning $original
$buildParameters = @{
    AppDir = $original; LayerRoot = $runtime; LayerSourceRoot = $layerSource
    OutputDir = $output; NodePath = $NodePath
    PortableCopy = $PortableCopy
}
if (-not [string]::IsNullOrWhiteSpace($AsarModule)) { $buildParameters.AsarModule = $AsarModule }

if (-not $PSCmdlet.ShouldProcess($original, 'Generate a patch from this clean version, back up its original pair, and apply the generated pair')) {
    $buildResult = & (Join-Path $PSScriptRoot 'Build-AppPatch.ps1') @buildParameters -Confirm:$false -WhatIf:$true
    [pscustomobject]@{
        status = 'validated-only'; appDir = $original
        outputDir = $buildResult.outputDir; patchedAppDir = $buildResult.patchedAppDir
        manifestPath = $buildResult.manifestPath; reportPath = $buildResult.reportPath
        backupDir = $null; backupRoot = $backupRootPath; nodePath = $buildResult.nodePath
        engineReport = $buildResult.engineReport
    }
    return
}

$buildResult = & (Join-Path $PSScriptRoot 'Build-AppPatch.ps1') @buildParameters -Confirm:$false -WhatIf:$false
if ($buildResult.status -cne 'prepared') { throw 'Repatch build did not prepare a pair. Nothing was applied.' }
# The existing apply tool rechecks target hashes, process state and paths, then backs up
# both files before replacing either. Its rollback and durable backup are unchanged.
$applyResult = & (Join-Path $PSScriptRoot 'Apply-AppPatch.ps1') -AppDir $original -PatchedAppDir $buildResult.patchedAppDir -ManifestPath $buildResult.manifestPath -BackupRoot $backupRootPath -Confirm:$false -WhatIf:$false
[pscustomobject]@{
    status = $applyResult.status; appDir = $original
    outputDir = $buildResult.outputDir; patchedAppDir = $buildResult.patchedAppDir
    manifestPath = $buildResult.manifestPath; reportPath = $buildResult.reportPath
    backupDir = $applyResult.backupDir; backupRoot = $backupRootPath; nodePath = $buildResult.nodePath
    engineReport = $buildResult.engineReport; applyResult = $applyResult
}
