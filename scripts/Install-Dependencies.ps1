[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$ProjectRoot = Get-AppDirectory $ProjectRoot
if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { throw 'Windows x64 is required.' }
$local = Assert-AppPlainPath (Join-Path $ProjectRoot '.local') -AllowMissing
[void][IO.Directory]::CreateDirectory($local)
$lock = [IO.File]::Open((Join-Path $local 'dependencies.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $runtime = (Read-AppJson (Join-Path $ProjectRoot 'runtime.lock.json')).node
    $tools = Assert-AppPlainPath (Join-Path $local 'tools') -AllowMissing
    [void][IO.Directory]::CreateDirectory($tools)
    $nodeRoot = Assert-AppPlainPath (Join-Path $tools $runtime.directory) -AllowMissing
    $node = Join-Path $nodeRoot 'node.exe'
    if (-not [IO.File]::Exists($node)) {
        $zip = Join-Path $tools ($runtime.directory + '.zip')
        Write-Host "Preparing private Node.js $($runtime.version)."
        if (-not [IO.File]::Exists($zip) -or (Get-FileHash -LiteralPath $zip).Hash -ine $runtime.sha256) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $runtime.url -OutFile $zip
        }
        if ((Get-FileHash -LiteralPath $zip).Hash -ine $runtime.sha256) { throw 'Node.js download checksum mismatch.' }
        Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
    }
    if ((& $node --version) -cne ('v' + $runtime.version)) { throw 'Private Node.js version mismatch.' }
    $dependencies = Assert-AppPlainPath (Join-Path $local 'dependencies') -AllowMissing
    [void][IO.Directory]::CreateDirectory($dependencies)
    $expected = (Get-FileHash -LiteralPath (Join-Path $ProjectRoot 'package-lock.json')).Hash
    $receipt = Join-Path $dependencies 'prepared-lock.sha256'
    $layer = Join-Path $dependencies 'node_modules/chatgpt-layer'
    $asar = Join-Path $dependencies 'node_modules/@electron/asar'
    $reusable = [IO.File]::Exists($receipt) -and [IO.File]::ReadAllText($receipt).Trim() -ceq $expected -and
        [IO.File]::Exists((Join-Path $layer 'assets/runtime/main.js')) -and [IO.File]::Exists((Join-Path $asar 'package.json'))
    if (-not $reusable) {
        foreach ($name in @('package.json','package-lock.json')) { [IO.File]::Copy((Join-Path $ProjectRoot $name),(Join-Path $dependencies $name),$true) }
        $oldPath = $env:PATH
        try {
            $env:PATH = $nodeRoot + ';' + $oldPath
            & $node (Join-Path $nodeRoot 'node_modules/npm/bin/npm-cli.js') ci --prefix $dependencies --omit=dev --ignore-scripts --no-audit --no-fund | Out-Host
            if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed. Retry Setup.cmd when the network is available.' }
        } finally { $env:PATH = $oldPath }
        [IO.File]::WriteAllText($receipt, $expected)
    }
    if ((Read-AppJson (Join-Path $layer 'package.json')).version -cne '1.1.4' -or (Read-AppJson (Join-Path $asar 'package.json')).version -cne '3.4.1') { throw 'Dependency version mismatch.' }
    # Read the upstream assets; never run Layer's installer against the Store app.
    $source = Assert-AppPlainPath (Join-Path $local 'layer-source') -AllowMissing
    $runtimeOut = Assert-AppPlainPath (Join-Path $local 'layer-runtime') -AllowMissing
    foreach ($p in @($source, $runtimeOut, (Join-Path $source 'assets'))) { [void][IO.Directory]::CreateDirectory($p) }
    foreach ($name in @('package.json','LICENSE')) { [IO.File]::Copy((Join-Path $layer $name),(Join-Path $source $name),$true) }
    [IO.File]::Copy((Join-Path $layer 'assets/loader.cjs'),(Join-Path $source 'assets/loader.cjs'),$true)
    Get-ChildItem -LiteralPath (Join-Path $layer 'assets/runtime') -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $runtimeOut -Recurse -Force }
    [IO.File]::Copy((Join-Path $layer 'LICENSE'),(Join-Path $runtimeOut 'LICENSE'),$true)
    & $node (Join-Path $PSScriptRoot 'patch-layer-runtime.cjs') --runtime-root $runtimeOut --check | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unsupported Layer runtime assets.' }
    [pscustomobject]@{ nodePath=$node; layerSource=$source; runtimeSource=$runtimeOut; asarModule=$asar }
} finally { $lock.Dispose() }
