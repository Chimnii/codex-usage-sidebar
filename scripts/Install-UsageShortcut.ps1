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
$paths = @()
if ($OutputPath) { $paths += $OutputPath }
else {
    $paths += (Join-Path $ProjectRoot 'Codex Usage Sidebar.lnk')
    $paths += (Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Usage Sidebar.lnk')
    if ($UpdateExistingPin) {
        $pin = Join-Path $env:APPDATA 'Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/Codex Usage Sidebar.lnk'
        if (Test-Path -LiteralPath $pin) { $paths += $pin }
    }
}
$shell = New-Object -ComObject WScript.Shell
$view = New-Object -ComObject Shell.Application
if (-not ('UsageSidebar.ShortcutProperties' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'ShortcutProperties.cs') }
foreach ($linkPath in $paths) {
    $full = Assert-AppPlainPath $linkPath -AllowMissing
    if ([IO.Path]::GetExtension($full) -ine '.lnk') { throw 'A .lnk output is required.' }
    if (-not $PSCmdlet.ShouldProcess($full, 'Point directly at the stable executable and assign its matching taskbar AppUserModelID')) { continue }
    [void][IO.Directory]::CreateDirectory((Split-Path $full -Parent))
    if (Test-Path -LiteralPath $full) {
        # Preserve the previous shortcut once, without recursively copying Shell data.
        $backup = Join-Path $ProjectRoot '.local/copy/shortcut-backup'
        [void][IO.Directory]::CreateDirectory($backup)
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($full))).Replace('-','').Substring(0,12)
        $saved = Join-Path $backup ($hash + '.lnk')
        if (-not (Test-Path -LiteralPath $saved)) { [IO.File]::Copy($full,$saved,$false) }
    }
    $link = $shell.CreateShortcut($full)
    $link.TargetPath = $exe; $link.Arguments = ''; $link.WorkingDirectory = $copy.appDir
    $link.IconLocation = $exe + ',0'; $link.Description = 'Codex Usage Sidebar'; $link.Save()
    [UsageSidebar.ShortcutProperties]::Apply($full,'Local.CodexUsageSidebar',$exe)
    $readback = $shell.CreateShortcut($full)
    $id = $view.Namespace((Split-Path $full -Parent)).ParseName((Split-Path $full -Leaf)).ExtendedProperty('System.AppUserModel.ID')
    if ($readback.TargetPath -ine $exe -or $readback.Arguments -ne '' -or $id -cne 'Local.CodexUsageSidebar') { throw "Shortcut readback failed: $full" }
    [pscustomobject]@{ path=$full; target=$readback.TargetPath; arguments=$readback.Arguments; appUserModelId=$id }
}
