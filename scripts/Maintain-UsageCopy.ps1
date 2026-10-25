[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
$base = Join-Path $ProjectRoot '.local/copy'
$lock = $null
try {
    $lock = [IO.File]::Open((Join-Path $base 'prepare.lock'),'OpenOrCreate','ReadWrite','None')
    if (-not (Test-Path -LiteralPath (Join-Path $base 'activation.json'))) { Invoke-UsageCopyCleanup $ProjectRoot }
} catch { } finally { if ($lock) { $lock.Dispose() } }
