[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Setup','Launch','Update','Restore','Uninstall')][string]$Action,
      [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
      [Parameter(ValueFromRemainingArguments=$true)][string[]]$Forward)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath
try {
    # Keep ordinary end-user entry points small; advanced flags use the PS1 directly.
    if ($Forward.Count) { throw 'For advanced options, use the PowerShell command in docs/SETUP.md.' }
    switch ($Action) {
        'Setup' { & (Join-Path $PSScriptRoot 'Setup.ps1') -ProjectRoot $ProjectRoot | Out-Host }
        'Launch' { & (Join-Path $PSScriptRoot 'Start-UsageCopy.ps1') -ProjectRoot $ProjectRoot }
        'Update' { & (Join-Path $PSScriptRoot 'Update-UsageCopy.ps1') -ProjectRoot $ProjectRoot -Confirm:$false }
        'Restore' { & (Join-Path $PSScriptRoot 'Restore-Copy.ps1') -ProjectRoot $ProjectRoot -Confirm:$false }
        'Uninstall' { & (Join-Path $PSScriptRoot 'Uninstall.ps1') -ProjectRoot $ProjectRoot -Confirm:$false }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'No running app was forcibly closed. See docs/SETUP.md for setup and recovery.'
    exit 1
}
