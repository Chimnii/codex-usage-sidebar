[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$SettingsPath,
    [string]$LayerDataRoot,
    [string]$ManagedAppDir,
    [switch]$AllowFixture
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $ProjectRoot 'patcher\AppPatch.Common.psm1') -Force -DisableNameChecking

function Get-UsageRequiredProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object.PSObject.Properties[$Name] -or [string]::IsNullOrWhiteSpace([string]$Object.$Name)) {
        throw "Missing local setting: $Name"
    }
    return [string]$Object.$Name
}

function Get-UsageFile {
    param([string]$Path)
    $full = Assert-AppPlainPath $Path
    if (-not [IO.File]::Exists($full)) { throw "Required file not found: $full" }
    return $full
}

function Get-UsageTree {
    param([string]$Source, [string]$Destination)
    $sourceRoot = Get-AppDirectory $Source
    $destinationRoot = Assert-AppPlainPath $Destination -AllowMissing
    Assert-AppSeparatePaths $sourceRoot $destinationRoot
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($sourceRoot)
    $entries = New-Object 'System.Collections.Generic.List[object]'
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Force)) {
            # Do not traverse links; inspect each level before enqueueing it.
            [void](Assert-AppPlainPath $entry.FullName)
            $relative = $entry.FullName.Substring($sourceRoot.Length).TrimStart([char[]]@('\', '/'))
            $target = Assert-AppPlainPath (Join-Path $destinationRoot $relative) -AllowMissing
            if ($entry.PSIsContainer) {
                if ([IO.File]::Exists($target)) { throw "Destination must be a directory: $target" }
                $pending.Enqueue($entry.FullName)
            }
            elseif ([IO.Directory]::Exists($target)) { throw "Destination must be a file: $target" }
            $entries.Add([pscustomobject]@{ source = $entry.FullName; destination = $target; isDirectory = $entry.PSIsContainer })
        }
    }
    return $entries.ToArray()
}

function Copy-UsageTree {
    param([string]$Destination, [object[]]$Entries)
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($entry in $Entries) {
        [void](Assert-AppPlainPath $entry.source)
        [void](Assert-AppPlainPath $entry.destination -AllowMissing)
        if ($entry.isDirectory) { [void][IO.Directory]::CreateDirectory($entry.destination) }
        else {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($entry.destination))
            [IO.File]::Copy($entry.source, $entry.destination, $true)
        }
    }
}

function Copy-UsageCli {
    param([string]$Source, [string]$Destination, $Expected)
    [void](Assert-AppPlainPath $Source)
    [void](Assert-AppPlainPath $Destination -AllowMissing)
    $parent = [IO.Path]::GetDirectoryName($Destination)
    [void][IO.Directory]::CreateDirectory($parent)
    $stage = Join-Path $parent ('.codex-cli-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Assert-AppIdentity $Source $Expected
        [IO.File]::Copy($Source, $stage, $false)
        Assert-AppIdentity $stage $Expected
        # Detect a package update during staging before publishing the executable.
        Assert-AppIdentity $Source $Expected
        if ([IO.File]::Exists($Destination)) { Invoke-AppFileReplace $stage $Destination }
        else { [IO.File]::Move($stage, $Destination) }
        Assert-AppIdentity $Destination $Expected
    }
    finally {
        if ([IO.File]::Exists($stage)) {
            [void](Assert-AppPlainPath $stage)
            [IO.File]::Delete($stage)
        }
    }
}

function Invoke-UsageRuntimePatch {
    param([string]$NodePath, [string]$HelperPath, [string]$RuntimeRoot, [switch]$Check)
    $saved = @{}
    try {
        foreach ($key in @('NODE_OPTIONS', 'NODE_PATH', 'ELECTRON_RUN_AS_NODE')) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            [Environment]::SetEnvironmentVariable($key, $null, 'Process')
        }
        $arguments = @($HelperPath, '--runtime-root', $RuntimeRoot)
        if ($Check) { $arguments += '--check' }
        $output = & $NodePath @arguments
        if ($LASTEXITCODE -ne 0) { throw "Layer runtime compatibility validation failed (exit $LASTEXITCODE)." }
        return ($output -join "`n" | ConvertFrom-Json)
    }
    finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

$ProjectRoot = Get-AppDirectory $ProjectRoot
$AppDir = Get-AppDirectory $AppDir
if ($AllowFixture) {
    # Synthetic integration targets are confined to the explicit local test tree.
    if (-not (Test-AppPathInside $AppDir (Join-Path $ProjectRoot '.local\tests'))) {
        throw 'Fixture app must be inside this project .local/tests directory.'
    }
}
else { Assert-AppSeparatePaths $ProjectRoot $AppDir }
if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $ProjectRoot '.local\settings.json' }
$SettingsPath = Get-UsageFile $SettingsPath
$settings = Read-AppJson $SettingsPath
if ($null -eq $settings.PSObject.Properties['schemaVersion'] -or $settings.schemaVersion -ne 1) { throw 'Unsupported local settings schema.' }
$expectedSid = Get-UsageRequiredProperty $settings 'userSid'
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($currentSid -cne $expectedSid) { throw 'Run this project as the Windows account recorded in .local/settings.json.' }
$nodePath = Get-UsageFile (Get-UsageRequiredProperty $settings 'nodePath')
$agyPath = $null
$antigravityEnabled = $settings.PSObject.Properties['agyPath'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.agyPath)
if ($settings.PSObject.Properties['agyPath'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.agyPath) -and [IO.File]::Exists($settings.agyPath)) { $agyPath = Get-UsageFile $settings.agyPath }
$codexHome = Get-AppDirectory (Get-UsageRequiredProperty $settings 'codexHome')
$userProfile = Get-AppDirectory (Get-UsageRequiredProperty $settings 'userProfile')
$claudeCredentialsPath = Join-Path $userProfile '.claude/.credentials.json'
if ($settings.PSObject.Properties['claudeCredentialsPath'] -and -not [string]::IsNullOrWhiteSpace([string]$settings.claudeCredentialsPath)) { $claudeCredentialsPath = [string]$settings.claudeCredentialsPath }
$claudeCredentialsPath = Assert-AppPlainPath $claudeCredentialsPath -AllowMissing
$claudeEnabled = -not $settings.PSObject.Properties['claudeEnabled'] -or [bool]$settings.claudeEnabled
if (-not $claudeEnabled) { $claudeCredentialsPath = $null }
$usage = [pscustomobject]@{}
if ($settings.PSObject.Properties['usage'] -and $null -ne $settings.usage) {
    if ($settings.usage -isnot [pscustomobject] -and $settings.usage -isnot [System.Collections.IDictionary]) { throw 'The usage setting must be a JSON object.' }
    $usage = $settings.usage
}
$localAppData = Get-AppDirectory (Get-UsageRequiredProperty $settings 'localAppData')
$appData = Get-AppDirectory (Get-UsageRequiredProperty $settings 'appData')
$originalCliPath = Get-UsageFile (Join-Path $AppDir 'resources\codex.exe')
$originalCliIdentity = Get-AppIdentity $originalCliPath
[void](Get-UsageFile (Join-Path $AppDir 'ChatGPT.exe'))
[void](Get-UsageFile (Join-Path $AppDir 'resources\app.asar'))

$layerSourceRoot = Get-AppDirectory (Join-Path $ProjectRoot '.local\layer-source')
$layerPackage = Read-AppJson (Join-Path $layerSourceRoot 'package.json')
if ($layerPackage.version -cne '1.1.4') { throw 'This adapter requires ChatGPT Layer exactly 1.1.4.' }
$runtimeSource = Get-AppDirectory (Join-Path $ProjectRoot '.local\layer-runtime')
[void](Get-UsageFile (Join-Path $runtimeSource 'main.js'))
[void](Get-UsageFile (Join-Path $runtimeSource 'LICENSE'))
$asarModule = Get-AppDirectory (Join-Path $ProjectRoot '.local\dependencies\node_modules\@electron\asar')
$asarPackage = Read-AppJson (Join-Path $asarModule 'package.json')
if ($asarPackage.version -cne '3.4.1') { throw 'This adapter requires @electron/asar exactly 3.4.1.' }
$tweakSource = Get-AppDirectory (Join-Path $ProjectRoot 'tweak')
$collectorSource = Get-AppDirectory (Join-Path $ProjectRoot 'collector')
$manifest = Read-AppJson (Join-Path $tweakSource 'manifest.json')
if ($manifest.id -cne 'local.sidebar-usage-demo') { throw 'Unexpected usage tweak identifier.' }
$helperPath = Get-UsageFile (Join-Path $PSScriptRoot 'patch-layer-runtime.cjs')
$runtimeCheck = Invoke-UsageRuntimePatch $nodePath $helperPath $runtimeSource -Check

if ([string]::IsNullOrWhiteSpace($LayerDataRoot)) { $LayerDataRoot = Join-Path $ProjectRoot '.local\layer-data' }
$layerRoot = Assert-AppPlainPath $LayerDataRoot -AllowMissing
if (-not (Test-AppPathInside $layerRoot (Join-Path $ProjectRoot '.local'))) { throw 'LayerDataRoot must stay inside this project .local directory.' }
foreach ($source in @($runtimeSource, $tweakSource, $layerSourceRoot, $asarModule, $AppDir)) { Assert-AppSeparatePaths $layerRoot $source }
$runtimeRoot = Join-Path $layerRoot 'runtime'
$tweakRoot = Join-Path $layerRoot 'tweaks\local.sidebar-usage-demo'
$tweakDataRoot = Join-Path $layerRoot 'tweak-data\local.sidebar-usage-demo'
$collectorWorkDir = Join-Path $layerRoot 'collector-work'
$codexPath = Join-Path $layerRoot 'bin\codex.exe'
if ($ManagedAppDir) {
    $managed = Get-AppDirectory $ManagedAppDir
    $expected = Join-Path $ProjectRoot '.local/copy/staging/app'
    if ($managed -ine $expected -or $layerRoot -ine (Join-Path $ProjectRoot '.local/copy/staging/layer-data')) { throw 'Managed CLI must belong to this staging app.' }
    $codexPath = Get-UsageFile (Join-Path $managed 'resources/codex.exe')
    if ((Get-Item -LiteralPath $codexPath).Length -ne $originalCliIdentity.length) { throw 'Managed CLI copy length mismatch.' }
}
$collectorConfigPath = Join-Path $tweakDataRoot 'collector-config.json'
$configPath = Join-Path $layerRoot 'config.json'
$cachePath = Join-Path $tweakDataRoot 'usage-cache.json'
foreach ($path in @($runtimeRoot, $tweakRoot, $tweakDataRoot, $collectorWorkDir, $collectorConfigPath, $configPath, $cachePath, $codexPath)) {
    [void](Assert-AppPlainPath $path -AllowMissing)
}
$runtimeFiles = @(Get-UsageTree $runtimeSource $runtimeRoot)
$tweakFiles = @(Get-UsageTree $tweakSource $tweakRoot)
$collectorFiles = @(Get-UsageTree $collectorSource (Join-Path $tweakRoot 'collector') | Where-Object { $_.isDirectory -or $_.source -notlike '*.test.cjs' })
$result = [ordered]@{
    status = 'what-if'; appDir = $AppDir; settingsPath = $SettingsPath; nodePath = $nodePath
    layerRoot = $layerRoot; layerSourceRoot = $layerSourceRoot; asarModule = $asarModule
    runtimeRoot = $runtimeRoot; tweakRoot = $tweakRoot; collectorConfigPath = $collectorConfigPath
    cachePath = $cachePath; intervalMs = 60000; layerVersion = '1.1.4'; runtimeCorrection = $runtimeCheck
    codexPath = $codexPath; originalCliPath = $originalCliPath; copyHash = $originalCliIdentity.sha256
    cliCopyLength = $originalCliIdentity.length
}
if (-not $PSCmdlet.ShouldProcess($layerRoot, 'Prepare the isolated Layer runtime and production usage collector settings')) {
    return [pscustomobject]$result
}
# A fresh runtime cannot be loaded by this package yet. Existing runtime updates require
# the selected app to be fully stopped; the one-command entry point also checks this.
if ([IO.File]::Exists((Join-Path $runtimeRoot 'main.js'))) { Assert-AppNotRunning $AppDir }

Copy-UsageTree $runtimeRoot $runtimeFiles
Copy-UsageTree $tweakRoot $tweakFiles
Copy-UsageTree (Join-Path $tweakRoot 'collector') $collectorFiles
$runtimePatch = Invoke-UsageRuntimePatch $nodePath $helperPath $runtimeRoot
foreach ($directory in @($tweakDataRoot, $collectorWorkDir)) { [void][IO.Directory]::CreateDirectory($directory) }
# Store-packaged executables can be readable yet denied external launch. This is an
# unmodified CLI copy only; desktop sessions and authentication still use the real profile.
if (-not $ManagedAppDir) { Copy-UsageCli $originalCliPath $codexPath $originalCliIdentity }
$collector = [ordered]@{
    projectRoot = $ProjectRoot
    nodePath = $nodePath; codexPath = $codexPath; agyPath = $agyPath; codexHome = $codexHome
    originalCliPath = $originalCliPath; cliSha256 = $originalCliIdentity.sha256
    userProfile = $userProfile; localAppData = $localAppData; appData = $appData
    claudeCredentialsPath = $claudeCredentialsPath
    providerEnabled = [ordered]@{ antigravity = [bool]$antigravityEnabled; claude = [bool]$claudeEnabled }
    usage = $usage
    workDir = $collectorWorkDir; cachePath = $cachePath; timeoutMs = 20000; intervalMs = 60000
}
$layerConfig = [ordered]@{
    codexPlusPlus = [ordered]@{ autoUpdate = $false; safeMode = $false }
    tweaks = [ordered]@{ 'local.sidebar-usage-demo' = [ordered]@{ enabled = $true } }
}
Write-AppJson $collectorConfigPath $collector
Write-AppJson $configPath $layerConfig
# No cache/log/auth/profile copying: valid existing usage-cache.json is left byte-for-byte intact.
$result.status = 'prepared'
$result.runtimeCorrection = $runtimePatch
return [pscustomobject]$result
