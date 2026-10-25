[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][UInt64]$WindowHandle,
    [Parameter(Mandatory=$true)][string]$Executable,
    [Parameter(Mandatory=$true)][string]$IconPath
)
$ErrorActionPreference = 'Stop'
# One bounded operation per window/theme change; never a resident service.
# The native helper verifies the HWND's owning executable before writing.
Add-Type -Path (Join-Path $PSScriptRoot 'ShortcutProperties.cs')
$window = [IntPtr]::new([Int64]$WindowHandle)
if ([UsageSidebar.ShortcutProperties]::ApplyWindow($window,'Local.CodexUsageSidebar',$Executable,$IconPath)) {
    $name = [UsageSidebar.ShortcutProperties]::ReadWindowProperty($window,4)
    $icon = [UsageSidebar.ShortcutProperties]::ReadWindowProperty($window,3)
    if ($name -cne [UsageSidebar.ShortcutProperties]::DisplayName -or $icon -ine ($IconPath + ',0')) { throw 'Window identity readback failed.' }
    [pscustomobject]@{status='applied';displayName=$name;icon=$icon} | ConvertTo-Json -Compress
}
