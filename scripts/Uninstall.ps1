[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
Assert-UsageCopyStopped
$ProjectRoot = Get-AppDirectory $ProjectRoot
$base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy') -AllowMissing
$settingsFile = Join-Path $ProjectRoot '.local/settings.json'
if (Test-Path -LiteralPath $settingsFile) {
    $s = (Get-UsageSettings $ProjectRoot).value
    foreach ($profile in @($s.codexHome,(Join-Path $s.appData 'Codex'))) { Assert-AppSeparatePaths $base $profile }
}
if (Test-Path -LiteralPath $base) { $null = @(Get-UsageCopyTree $base) }
if (-not $PSCmdlet.ShouldProcess($base,'Remove managed app copies and their shortcuts; keep all account data and original Store app')) { return }
$shell = New-Object -ComObject WScript.Shell
$locks = @()
try {
if (Test-Path -LiteralPath $base) {
    # Keep the three empty lock files so their handles can block competing
    # launchers/updaters throughout removal, including on Windows PowerShell 5.
    foreach ($name in @('start.lock','update.lock','prepare.lock')) {
        $locks += [IO.File]::Open((Join-Path $base $name),'OpenOrCreate','ReadWrite',[IO.FileShare]::None)
    }
}
$links = @(
    (Join-Path $ProjectRoot 'Codex Usage Sidebar.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Usage Sidebar.lnk'),
    (Join-Path $env:APPDATA 'Microsoft/Internet Explorer/Quick Launch/User Pinned/TaskBar/Codex Usage Sidebar.lnk')
)
foreach ($link in $links) {
    if ([IO.File]::Exists($link)) {
        $target = $shell.CreateShortcut($link).TargetPath
        if ($target -and (Test-AppPathInside $target $base)) { Remove-Item -LiteralPath $link }
    }
}
if (Test-Path -LiteralPath $base) {
    $null = @(Get-UsageCopyTree $base)
    foreach ($item in @(Get-ChildItem -LiteralPath $base -Force)) {
        if ($item.Name -in @('start.lock','update.lock','prepare.lock')) { continue }
        $owned = Assert-AppPlainPath $item.FullName
        if ((Split-Path $owned -Parent) -ine $base) { throw 'Invalid uninstall boundary.' }
        Remove-Item -LiteralPath $owned -Recurse -Force
    }
}
} finally { foreach ($held in $locks) { $held.Dispose() } }
Write-Host 'Managed copies and shortcuts removed. The Store app, login data, conversations and project sources remain.'
