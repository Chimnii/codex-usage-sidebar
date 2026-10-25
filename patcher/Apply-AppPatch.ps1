[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$PatchedAppDir,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [Parameter(Mandatory = $true)][string]$BackupRoot
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppPatch.Common.psm1') -Force -DisableNameChecking

$target = Get-AppDirectory $AppDir
$patched = Get-AppDirectory $PatchedAppDir
Assert-AppSeparatePaths $target $patched
$backupRootPath = Assert-AppPlainPath $BackupRoot -AllowMissing
Assert-AppSeparatePaths $backupRootPath $target
Assert-AppSeparatePaths $backupRootPath $patched
$manifest = Read-AppPatchManifest $ManifestPath
foreach ($entry in @($manifest.files)) { Assert-AppIdentity (Get-AppPairPath $patched $entry.path) $entry.patched }
$states = @(Get-AppPairStates $target $manifest)
if (@($states | Where-Object { $_.state -eq 'unknown' }).Count -gt 0) { throw 'Target files do not match this exact original/patched version. No files were replaced.' }
if (@($states | Where-Object { $_.state -eq 'patched' }).Count -eq 2) {
    [pscustomobject]@{ status = 'already-patched'; appDir = $target; backupDir = $null }
    return
}
if (@($states | Where-Object { $_.state -eq 'original' }).Count -ne 2) { throw 'Target contains a mixed file pair. Restore the verified backup before applying again.' }
Assert-AppBuildMatch (Get-AppBuild $target) (Get-AppBuild $patched)
Assert-AppNotRunning $target
if (-not $PSCmdlet.ShouldProcess($target, 'Back up both original files, then replace app.asar and ChatGPT.exe with the verified patched pair')) {
    [pscustomobject]@{ status = 'validated-only'; appDir = $target; backupRoot = $backupRootPath }
    return
}

$mutex = Enter-AppPatchLock $target
$backupDir = $null
try {
    Assert-AppNotRunning $target
    foreach ($entry in @($manifest.files)) {
        Assert-AppIdentity (Get-AppPairPath $target $entry.path) $entry.original
        Assert-AppIdentity (Get-AppPairPath $patched $entry.path) $entry.patched
    }
    [void](Assert-AppPlainPath $backupRootPath -AllowMissing)
    [void][IO.Directory]::CreateDirectory($backupRootPath)
    $backupDir = [IO.Path]::Combine($backupRootPath, ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')))
    if ([IO.Directory]::Exists($backupDir) -or [IO.File]::Exists($backupDir)) { throw "Backup path already exists: $backupDir" }
    [void][IO.Directory]::CreateDirectory($backupDir)
    [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($backupDir, 'resources'))
    foreach ($entry in @($manifest.files)) {
        $destination = [IO.Path]::Combine($backupDir, $entry.path.Replace('/', [IO.Path]::DirectorySeparatorChar))
        Copy-AppVerifiedFile (Get-AppPairPath $target $entry.path) $destination $entry.original
    }
    $metadata = [pscustomobject]@{
        schemaVersion = 1
        kind = 'layer-app-file-pair-backup'
        appDir = $target
        createdAt = [DateTime]::UtcNow.ToString('o')
        updatedAt = [DateTime]::UtcNow.ToString('o')
        state = 'backup-verified'
        patchManifest = $manifest
    }
    $metadataPath = [IO.Path]::Combine($backupDir, 'backup-manifest.json')
    Write-AppJson $metadataPath $metadata -CreateNew
    # Read the durable metadata and both backups before changing either target file.
    [void](Read-AppJson $metadataPath)
    $replacements = @()
    foreach ($entry in @($manifest.files)) {
        $backupFile = Get-AppPairPath $backupDir $entry.path
        Assert-AppIdentity $backupFile $entry.original
        $replacements += [pscustomobject]@{
            destination = Get-AppPairPath $target $entry.path
            newSource = Get-AppPairPath $patched $entry.path
            newIdentity = $entry.patched
            oldSource = $backupFile
            oldIdentity = $entry.original
        }
    }
    try {
        Assert-AppNotRunning $target
        Invoke-AppPairReplacement $replacements
    }
    catch {
        $applyFailure = $_.Exception
        $metadata.state = 'apply-failed-rolled-back'
        if ($applyFailure.Data['RecoveryRequired']) { $metadata.state = 'apply-failed-recovery-required' }
        $metadata.updatedAt = [DateTime]::UtcNow.ToString('o')
        try { Write-AppJson $metadataPath $metadata } catch { Write-Warning "Could not update backup status: $($_.Exception.Message)" }
        throw (New-AppOperationException "Apply failed. Backup retained at '$backupDir'. $($applyFailure.Message)" $applyFailure)
    }
    $metadata.state = 'applied'
    $metadata.updatedAt = [DateTime]::UtcNow.ToString('o')
    try { Write-AppJson $metadataPath $metadata } catch { Write-Warning "The patch was applied, but backup status could not be updated: $($_.Exception.Message)" }
    [pscustomobject]@{ status = 'applied'; appDir = $target; backupDir = $backupDir; backupManifestPath = $metadataPath; warnings = @(Get-AppOperationWarnings) }
}
finally { Exit-AppPatchLock $mutex }
