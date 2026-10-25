[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ProjectRoot, [string]$OutputPath, [switch]$UpdateExistingPin)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$copy = Read-UsageCopyCurrent $ProjectRoot
if (-not $copy -or $copy.schemaVersion -ne 2) { throw 'Prepare the fixed copy first.' }
Assert-UsageCopyPair $copy
$exe = Join-Path $copy.appDir 'ChatGPT.exe'
$base = Join-Path $ProjectRoot '.local/copy'
if (-not ('UsageSidebar.ShortcutProperties' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ShortcutProperties.cs') }
$displayName = [UsageSidebar.ShortcutProperties]::DisplayName
$paths = @()
$legacyLinks = @()
function Test-OwnedShortcut([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $false }
    try { $info = [UsageSidebar.ShortcutProperties]::Read($Path) } catch { return $false }
    return ($info.TargetPath -and (Test-AppPathInside $info.TargetPath $base))
}
function Save-ShortcutBackup([string]$Path) {
    $backup = Join-Path $base 'shortcut-backup'
    [void][IO.Directory]::CreateDirectory($backup)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path))).Replace('-','').Substring(0,12) }
    finally { $sha.Dispose() }
    $saved = Join-Path $backup ($hash + '.lnk')
    if (-not [IO.File]::Exists($saved)) { [IO.File]::Copy($Path,$saved,$false) }
}
if ($OutputPath) { $paths += $OutputPath }
else {
    foreach ($folder in @($ProjectRoot, [Environment]::GetFolderPath('Programs'))) {
        $paths += (Join-Path $folder ($displayName + '.lnk'))
        foreach ($name in @('Codex Usage Sidebar.lnk', 'ChatGPT.lnk')) {
            $old = Join-Path $folder $name
            if (Test-OwnedShortcut $old) { $legacyLinks += $old }
        }
    }
    if ($UpdateExistingPin) {
        $pinFolder = Join-Path $env:APPDATA 'Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar'
        if ([IO.Directory]::Exists($pinFolder)) {
            foreach ($pin in @(Get-ChildItem -LiteralPath $pinFolder -Filter '*.lnk' -File)) {
                # Keep the pinned filename: Windows also tracks it in its own cache.
                if (Test-OwnedShortcut $pin.FullName) { $paths += $pin.FullName }
            }
        }
    }
}
foreach ($linkPath in $paths) {
    if ([IO.File]::Exists($linkPath) -and -not (Test-OwnedShortcut $linkPath)) { throw "A shortcut at this name belongs to another app; it was not replaced: $linkPath" }
}
foreach ($linkPath in $paths) {
    $full = Assert-AppPlainPath $linkPath -AllowMissing
    if ([IO.Path]::GetExtension($full) -ine '.lnk') { throw 'A .lnk output is required.' }
    if (-not $PSCmdlet.ShouldProcess($full, 'Point directly at the stable executable and assign its matching taskbar AppUserModelID')) { continue }
    [void][IO.Directory]::CreateDirectory((Split-Path $full -Parent))
    if (Test-Path -LiteralPath $full) {
        Save-ShortcutBackup $full
    }
    [UsageSidebar.ShortcutProperties]::Create($full,$exe,$copy.appDir)
    [UsageSidebar.ShortcutProperties]::Apply($full,'Local.CodexUsageSidebar',$exe)
    $readback = [UsageSidebar.ShortcutProperties]::Read($full)
    $id = [UsageSidebar.ShortcutProperties]::ReadAppId($full)
    if ($readback.TargetPath -ine $exe -or $readback.Arguments -ne '' -or $id -cne 'Local.CodexUsageSidebar' -or
        $readback.Description -cne $displayName -or [UsageSidebar.ShortcutProperties]::ReadDisplayName($full) -cne $displayName) { throw "Shortcut readback failed: $full" }
    [pscustomobject]@{ path=$full; target=$readback.TargetPath; arguments=$readback.Arguments; appUserModelId=$id; displayName=$displayName; icon=$readback.IconPath }
}
# Retire only obsolete aliases that resolve to this project's managed copy.
foreach ($old in $legacyLinks) {
    $full = Assert-AppPlainPath $old
    if ((Test-OwnedShortcut $full) -and $PSCmdlet.ShouldProcess($full, 'Back up and remove the old managed-copy shortcut name')) {
        Save-ShortcutBackup $full
        Remove-Item -LiteralPath $full
    }
}
