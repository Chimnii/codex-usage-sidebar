[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$BackupDir
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppPatch.Common.psm1') -Force -DisableNameChecking

$target = Get-AppDirectory $AppDir
$backup = Get-AppDirectory $BackupDir
Assert-AppSeparatePaths $target $backup
$metadataPath = [IO.Path]::Combine($backup, 'backup-manifest.json')
$metadata = Read-AppJson $metadataPath
if ($null -eq $metadata.PSObject.Properties['schemaVersion'] -or $null -eq $metadata.PSObject.Properties['kind'] -or
    $null -eq $metadata.PSObject.Properties['appDir'] -or $null -eq $metadata.PSObject.Properties['patchManifest'] -or
    $null -eq $metadata.PSObject.Properties['state'] -or $null -eq $metadata.PSObject.Properties['updatedAt']) { throw 'Missing backup metadata fields.' }
if ($metadata.schemaVersion -ne 1 -or $metadata.kind -cne 'layer-app-file-pair-backup') { throw 'Unsupported backup metadata format.' }
if ($metadata.appDir -isnot [string] -or -not [IO.Path]::IsPathRooted($metadata.appDir) -or
    -not (Get-AppFullPath $metadata.appDir).Equals($target, [StringComparison]::OrdinalIgnoreCase)) { throw 'This backup belongs to a different app directory. No files were replaced.' }
$manifest = $metadata.patchManifest
Assert-AppPatchManifest $manifest
foreach ($entry in @($manifest.files)) { Assert-AppIdentity (Get-AppPairPath $backup $entry.path) $entry.original }
$states = @(Get-AppPairStates $target $manifest)
if (@($states | Where-Object { $_.state -eq 'unknown' }).Count -gt 0) { throw 'Target files are unknown or from another app version. This backup will not overwrite them.' }
if (@($states | Where-Object { $_.state -eq 'original' }).Count -eq 2) {
    [pscustomobject]@{ status = 'already-original'; appDir = $target; backupDir = $backup }
    return
}
Assert-AppNotRunning $target
if (-not $PSCmdlet.ShouldProcess($target, 'Restore the verified original app.asar and ChatGPT.exe from the backup')) {
    [pscustomobject]@{ status = 'validated-only'; appDir = $target; backupDir = $backup; files = $states }
    return
}

$mutex = Enter-AppPatchLock $target
$rollbackFiles = New-Object 'Collections.Generic.List[string]'
$outerRestoreFailure = $null
$restoreResult = $null
try {
    Assert-AppNotRunning $target
    $current = @(Get-AppPairStates $target $manifest)
    if (@($current | Where-Object { $_.state -eq 'unknown' }).Count -gt 0) { throw 'Target changed while waiting; restore refused.' }
    $replacements = @()
    foreach ($entry in @($manifest.files)) {
        $backupFile = Get-AppPairPath $backup $entry.path
        Assert-AppIdentity $backupFile $entry.original
        $fileState = @($current | Where-Object { $_.path -ceq $entry.path })[0]
        if ($fileState.state -eq 'original') { continue }
        $destination = Get-AppPairPath $target $entry.path
        $rollbackFile = [IO.Path]::Combine([IO.Path]::GetDirectoryName($destination), '.app-restore-before-' + [guid]::NewGuid().ToString('N') + '.tmp')
        Copy-AppStagedFile $destination $rollbackFile $entry.patched
        $rollbackFiles.Add($rollbackFile)
        $replacements += [pscustomobject]@{
            destination = $destination
            newSource = $backupFile
            newIdentity = $entry.original
            oldSource = $rollbackFile
            oldIdentity = $entry.patched
        }
    }
    try {
        Assert-AppNotRunning $target
        if ($replacements.Count -gt 0) { Invoke-AppPairReplacement $replacements }
    }
    catch {
        $restoreFailure = $_.Exception
        $metadata.state = 'restore-failed-rolled-back'
        if ($restoreFailure.Data['RecoveryRequired']) { $metadata.state = 'restore-failed-recovery-required' }
        $metadata.updatedAt = [DateTime]::UtcNow.ToString('o')
        try { Write-AppJson $metadataPath $metadata } catch { Write-Warning "Could not update backup status: $($_.Exception.Message)" }
        throw (New-AppOperationException "Restore failed. Backup retained at '$backup'. $($restoreFailure.Message)" $restoreFailure)
    }
    foreach ($entry in @($manifest.files)) { Assert-AppIdentity (Get-AppPairPath $target $entry.path) $entry.original }
    $metadata.state = 'restored'
    $metadata.updatedAt = [DateTime]::UtcNow.ToString('o')
    try { Write-AppJson $metadataPath $metadata } catch { Write-Warning "Files were restored, but backup status could not be updated: $($_.Exception.Message)" }
    $restoreResult = [pscustomobject]@{ status = 'restored'; appDir = $target; backupDir = $backup; warnings = @() }
}
catch { $outerRestoreFailure = $_.Exception; throw }
finally {
    foreach ($temporary in $rollbackFiles) {
        try { if ([IO.File]::Exists($temporary)) { [void](Assert-AppPlainPath $temporary); [IO.File]::Delete($temporary) } }
        catch { Write-AppCleanupWarning 'cleanup-restore-snapshot' $temporary $_.Exception }
    }
    if ($null -ne $outerRestoreFailure) { $outerRestoreFailure.Data['AppCleanupErrors'] = @(Get-AppOperationWarnings) }
    Exit-AppPatchLock $mutex
}
if ($null -ne $restoreResult) { $restoreResult.warnings = @(Get-AppOperationWarnings); $restoreResult }
