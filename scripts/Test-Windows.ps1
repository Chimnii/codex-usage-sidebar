[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# npm can inherit PowerShell 7's module path when it starts Windows PowerShell.
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath
$root = Split-Path $PSScriptRoot -Parent
$shell = (Get-Process -Id $PID).Path
foreach ($name in @('patcher','repatch-workflow','usage-environment','usage-copy','usage-update','update-entry','release-setup')) {
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root ('tests/' + $name + '.test.ps1'))
    if ($LASTEXITCODE -ne 0) { throw "Failed: $name" }
}
