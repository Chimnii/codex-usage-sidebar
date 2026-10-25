[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
try {
    # Same entry point as Update.cmd; wait for a normal user-initiated quit.
    & (Join-Path $PSScriptRoot 'Update-UsageCopy.ps1') -ProjectRoot $ProjectRoot -WaitForExit -Confirm:$false
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'The copy was not restarted. Details: .local\copy\last-update-error.json'
    [void](Read-Host 'Press Enter to close this helper')
    exit 1
}
