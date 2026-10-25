[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$OriginalAppDir,
    [Parameter(Mandatory = $true)][string]$PatchedAppDir,
    [Parameter(Mandatory = $true)][string]$ManifestPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppPatch.Common.psm1') -Force -DisableNameChecking

$original = Get-AppDirectory $OriginalAppDir
$patched = Get-AppDirectory $PatchedAppDir
Assert-AppSeparatePaths $original $patched
$manifestFile = Assert-AppPlainPath $ManifestPath -AllowMissing
[void](Get-AppDirectory ([IO.Path]::GetDirectoryName($manifestFile)))
if ((Test-AppPathInside $manifestFile $original) -or (Test-AppPathInside $manifestFile $patched)) { throw 'Write the manifest outside both application directories.' }
if ([IO.File]::Exists($manifestFile)) { throw "Manifest already exists; choose a new name: $manifestFile" }
$originalBuild = Get-AppBuild $original
$patchedBuild = Get-AppBuild $patched
Assert-AppBuildMatch $originalBuild $patchedBuild
$files = @()
foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) {
    $files += [pscustomobject]@{
        path = $relative
        original = Get-AppIdentity (Get-AppPairPath $original $relative)
        patched = Get-AppIdentity (Get-AppPairPath $patched $relative)
    }
}
$manifest = [pscustomobject]@{
    schemaVersion = 1
    kind = 'layer-app-file-pair'
    createdAt = [DateTime]::UtcNow.ToString('o')
    build = $originalBuild
    files = $files
}
Assert-AppPatchManifest $manifest
if ($PSCmdlet.ShouldProcess($manifestFile, 'Create a manifest for the exact original and patched app file pair')) {
    Write-AppJson $manifestFile $manifest -CreateNew
    [pscustomobject]@{ status = 'manifest-created'; manifestPath = $manifestFile; files = $files }
}
else { [pscustomobject]@{ status = 'validated-only'; manifestPath = $manifestFile; files = $files } }
