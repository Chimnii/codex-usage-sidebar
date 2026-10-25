[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [Parameter(Mandatory = $true)][string]$LayerRoot,
    [Parameter(Mandatory = $true)][string]$LayerSourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$NodePath = 'node',
    [string]$AsarModule,
    [switch]$PortableCopy
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppPatch.Common.psm1') -Force -DisableNameChecking

function ConvertTo-RepatchNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW / C runtime quoting, without invoking a shell.
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-RepatchEngine {
    param([string]$Executable, [string[]]$Arguments)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-RepatchNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    # A user's Node preload/debug options must not add side effects to inspect/-WhatIf.
    [void]$start.EnvironmentVariables.Remove('NODE_OPTIONS')
    [void]$start.EnvironmentVariables.Remove('NODE_PATH')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the repatch engine.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Repatch engine failed (exit $($process.ExitCode)). $($stderr.Trim()) $($stdout.Trim())"
        }
        try { $report = $stdout | ConvertFrom-Json }
        catch { throw "Repatch engine did not return a single JSON report. $($_.Exception.Message)" }
        if ($null -eq $report -or $null -eq $report.PSObject.Properties['status']) { throw 'Missing repatch engine report status.' }
        return $report
    }
    finally { $process.Dispose() }
}

$original = Get-AppDirectory $AppDir
$runtime = Get-AppDirectory $LayerRoot
$layerSource = Get-AppDirectory $LayerSourceRoot
$output = Assert-AppPlainPath $OutputDir -AllowMissing
[void](Get-AppDirectory ([IO.Path]::GetDirectoryName($output)))
foreach ($inputPath in @($original, $runtime, $layerSource)) { Assert-AppSeparatePaths $output $inputPath }
if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { throw "OutputDir must be new and must not already exist: $output" }
foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) { [void](Get-AppPairPath $original $relative) }
$engine = Assert-AppPlainPath (Join-Path $PSScriptRoot 'repatch/cli.cjs')
if (-not [IO.File]::Exists($engine)) { throw "Repatch engine not found: $engine" }

if ([IO.Path]::IsPathRooted($NodePath) -or $NodePath.Contains('\') -or $NodePath.Contains('/')) {
    $nodeExecutable = Assert-AppPlainPath $NodePath
}
else {
    if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters($NodePath)) { throw 'NodePath cannot use command-name wildcards. Supply node or an absolute executable path.' }
    $nodeCommands = @(Get-Command $NodePath -CommandType Application -ErrorAction Stop)
    # Use normal PATH precedence when several installations provide the same command.
    if ($nodeCommands.Count -lt 1) { throw 'Node executable was not found. Supply an absolute NodePath.' }
    $nodeExecutable = Assert-AppPlainPath $nodeCommands[0].Source
}
if (-not [IO.File]::Exists($nodeExecutable)) { throw "Node executable not found: $nodeExecutable" }
if ([IO.Path]::GetExtension($nodeExecutable) -ine '.exe') { throw 'NodePath must resolve to an executable (.exe), not a shell script.' }

$patched = [IO.Path]::Combine($output, 'app')
$manifestPath = [IO.Path]::Combine($output, 'patch-manifest.json')
$pendingManifestPath = [IO.Path]::Combine($output, 'patch-manifest.pending.json')
$reportPath = [IO.Path]::Combine($patched, 'repatch-report.json')
$baseArguments = @('--original-app-dir', $original, '--layer-root', $runtime, '--layer-source-root', $layerSource)
if ($PortableCopy) { $baseArguments += @('--portable-copy', 'true') }
if (-not [string]::IsNullOrWhiteSpace($AsarModule)) {
    $asarModulePath = Assert-AppPlainPath $AsarModule
    if (Test-AppPathInside $asarModulePath $output) { throw 'AsarModule cannot be inside the new OutputDir.' }
    $baseArguments += @('--asar-module', $asarModulePath)
}

if (-not $PSCmdlet.ShouldProcess($output, 'Read the clean app, generate a newly patched file pair, and create its exact hash manifest')) {
    $report = Invoke-RepatchEngine $nodeExecutable (@($engine, 'inspect') + $baseArguments)
    if ($report.status -cne 'compatible') { throw "Unexpected inspect report status: $($report.status)" }
    [pscustomobject]@{
        status = 'validated-only'; appDir = $original; outputDir = $output
        patchedAppDir = $patched; manifestPath = $manifestPath; reportPath = $reportPath
        nodePath = $nodeExecutable; engineReport = $report
    }
    return
}

# Only this new output tree is written. On failure it is retained for diagnosis.
[void](Assert-AppPlainPath $output -AllowMissing)
if ([IO.File]::Exists($output) -or [IO.Directory]::Exists($output)) { throw "OutputDir appeared during validation: $output" }
[void][IO.Directory]::CreateDirectory($output)
try {
    $report = Invoke-RepatchEngine $nodeExecutable (@($engine, 'prepare') + $baseArguments + @('--output-app-dir', $patched))
    if ($report.status -cne 'prepared') { throw "Unexpected prepare report status: $($report.status)" }
    if ($null -eq $report.PSObject.Properties['outputAppDir'] -or
        -not (Get-AppFullPath ([string]$report.outputAppDir)).Equals($patched, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The engine returned a different output application directory.'
    }
    if ($null -eq $report.PSObject.Properties['files'] -or @($report.files).Count -ne 2) { throw 'The engine must report exactly the two app files.' }
    # Recheck inputs and generated files before writing a usable apply manifest.
    foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) {
        $matches = @($report.files | Where-Object { $null -ne $_.PSObject.Properties['path'] -and $_.path -ceq $relative })
        if ($matches.Count -ne 1) { throw "The engine returned a missing or duplicate file entry: $relative" }
        $entry = $matches[0]
        Assert-AppIdentityShape $entry.original
        Assert-AppIdentityShape $entry.patched
        Assert-AppIdentity (Get-AppPairPath $original $relative) $entry.original
        Assert-AppIdentity (Get-AppPairPath $patched $relative) $entry.patched
    }
    $manifestResult = & (Join-Path $PSScriptRoot 'New-PatchManifest.ps1') -OriginalAppDir $original -PatchedAppDir $patched -ManifestPath $pendingManifestPath -Confirm:$false -WhatIf:$false
    if ($manifestResult.status -cne 'manifest-created') { throw 'The patch manifest was not created.' }
    $manifest = Read-AppPatchManifest $pendingManifestPath
    foreach ($entry in @($manifest.files)) {
        $engineEntry = @($report.files | Where-Object { $_.path -ceq $entry.path })[0]
        if (-not (Test-AppIdentity $entry.original $engineEntry.original) -or
            -not (Test-AppIdentity $entry.patched $engineEntry.patched)) {
            throw 'An input or output changed while creating the patch manifest. Do not apply this output.'
        }
    }
    [void](Assert-AppPlainPath $manifestPath -AllowMissing)
    # Publish the apply manifest only after it agrees with the engine's input/output snapshot.
    [IO.File]::Move($pendingManifestPath, $manifestPath)
    [pscustomobject]@{
        status = 'prepared'; appDir = $original; outputDir = $output
        patchedAppDir = $patched; manifestPath = $manifestPath; reportPath = $reportPath
        nodePath = $nodeExecutable; engineReport = $report
    }
}
catch {
    throw "Build failed. The target app was not changed by this command. Inspect retained output '$output' before using it. $($_.Exception.Message)"
}
