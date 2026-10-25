Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:AllowedFiles = @('resources/app.asar', 'ChatGPT.exe')
$script:AppOperationWarnings = New-Object 'Collections.Generic.List[object]'

function Write-AppCleanupWarning {
    param([string]$Operation, [string]$Path, [Exception]$Exception)
    $script:AppOperationWarnings.Add([pscustomobject]@{
        operation = $Operation; path = $Path; message = $Exception.Message; hresult = $Exception.HResult
    })
    Write-Warning "Cleanup operation '$Operation' needs attention at '$Path': $($Exception.Message)"
}

function Get-AppOperationWarnings {
    return $script:AppOperationWarnings.ToArray()
}

function Get-AppPathObservation {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [pscustomobject]@{ observed = $true; exists = $true; attributes = [string]$item.Attributes; isDirectory = $item.PSIsContainer }
    }
    catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return [pscustomobject]@{ observed = $true; exists = $false } }
        return [pscustomobject]@{ observed = $false; error = $_.Exception.Message }
    }
}

function Get-AppFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An explicit filesystem path is required.' }
    # Check aliases before the provider or .NET normalizes away trailing characters.
    foreach ($part in @($Path -split '[\\/]')) {
        if ($part -eq '.' -or $part -eq '..') { continue }
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "Paths with trailing dots or spaces are not supported: $Path" }
    }
    $providerInfo = $null
    $driveInfo = $null
    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$providerInfo, [ref]$driveInfo)
    if ($providerInfo.Name -ne 'FileSystem') { throw 'Only filesystem paths are supported.' }
    foreach ($part in @($providerPath -split '[\\/]')) {
        if ($part -eq '.' -or $part -eq '..') { continue }
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "Paths with trailing dots or spaces are not supported: $Path" }
    }
    $full = [IO.Path]::GetFullPath($providerPath)
    if ($full.StartsWith('\\?\') -or $full.StartsWith('\\.\')) { throw 'Device and extended-length path aliases are not supported.' }
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    if ($full.Substring($root.Length).Contains(':')) { throw "Alternate data stream paths are not supported: $full" }
    foreach ($part in @($full.Substring($root.Length) -split '[\\/]')) {
        if ($part.EndsWith('.') -or $part.EndsWith(' ')) { throw "Paths with trailing dots or spaces are not supported: $full" }
    }
    return $full
}

function Assert-AppPlainPath {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$AllowMissing)
    $full = Get-AppFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $parts = @($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_.Length -gt 0 })
    $cursor = $root
    $paths = @($root)
    foreach ($part in $parts) { $cursor = [IO.Path]::Combine($cursor, $part); $paths += $cursor }
    foreach ($candidate in $paths) {
        try { $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop }
        catch {
            if ($AllowMissing -and $_.CategoryInfo.Category -eq 'ObjectNotFound') { continue }
            throw
        }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points, symlinks and junctions are not allowed: $candidate"
        }
    }
    return $full
}

function Get-AppDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-AppPlainPath $Path
    if (-not [IO.Directory]::Exists($full)) { throw "Directory not found: $full" }
    return $full
}

function Test-AppPathInside {
    param([string]$Path, [string]$Directory)
    $a = Get-AppFullPath $Path
    $b = Get-AppFullPath $Directory
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or
        $a.StartsWith($b.TrimEnd([char[]]@('\', '/')) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AppSeparatePaths {
    param([string]$First, [string]$Second)
    if ((Test-AppPathInside $First $Second) -or (Test-AppPathInside $Second $First)) {
        throw "Directories must be separate and must not contain one another: '$First' and '$Second'."
    }
}

function Get-AppPairPath {
    param([string]$AppDir, [string]$RelativePath)
    if ($script:AllowedFiles -cnotcontains $RelativePath) { throw "Unsupported app file: $RelativePath" }
    $full = [IO.Path]::Combine($AppDir, $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    return (Assert-AppPlainPath $full)
}

function Get-AppIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-AppPlainPath $Path
    $item = Get-Item -LiteralPath $full -Force
    if ($item.PSIsContainer) { throw "Expected a file: $full" }
    # PS5's Get-FileHash helper can inherit WhatIf and suppress ProviderPath
    # lookup in a fresh shell. Hash directly so validation always reads bytes.
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($full)
        $length = $stream.Length
        $hash = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '')
        return [pscustomobject]@{ sha256 = $hash; length = [long]$length }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $algorithm.Dispose()
    }
}

function Assert-AppIdentityShape {
    param($Identity)
    if ($null -eq $Identity -or $null -eq $Identity.PSObject.Properties['sha256'] -or $null -eq $Identity.PSObject.Properties['length']) {
        throw 'A file identity requires sha256 and length.'
    }
    if ($Identity.sha256 -isnot [string] -or $Identity.sha256 -cnotmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid SHA256 identity.' }
    if (($Identity.length -isnot [int] -and $Identity.length -isnot [long]) -or $Identity.length -lt 1) { throw 'Invalid file length.' }
}

function Test-AppIdentity {
    param($Actual, $Expected)
    return ([string]$Actual.sha256).Equals([string]$Expected.sha256, [StringComparison]::OrdinalIgnoreCase) -and ([long]$Actual.length -eq [long]$Expected.length)
}

function Assert-AppIdentity {
    param([string]$Path, $Expected)
    $actual = Get-AppIdentity $Path
    if (-not (Test-AppIdentity $actual $Expected)) { throw "File hash or length does not match the expected version: $Path" }
}

function Get-AppBuild {
    param([string]$AppDir)
    $exe = Get-AppPairPath $AppDir 'ChatGPT.exe'
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    return [pscustomobject]@{ fileVersion = $version.FileVersion; productVersion = $version.ProductVersion }
}

function Assert-AppBuildMatch {
    param($OriginalBuild, $PatchedBuild)
    foreach ($key in @('fileVersion', 'productVersion')) {
        $a = [string]$OriginalBuild.$key
        $b = [string]$PatchedBuild.$key
        if (-not [string]::IsNullOrWhiteSpace($a) -and -not [string]::IsNullOrWhiteSpace($b) -and $a -cne $b) {
            throw "Executable $key differs between the original and patched pair ('$a' / '$b')."
        }
    }
}

function Assert-AppPatchManifest {
    param($Manifest)
    if ($null -eq $Manifest -or $null -eq $Manifest.PSObject.Properties['schemaVersion'] -or
        $null -eq $Manifest.PSObject.Properties['kind'] -or $null -eq $Manifest.PSObject.Properties['files']) { throw 'Missing patch manifest fields.' }
    if (($Manifest.schemaVersion -isnot [int] -and $Manifest.schemaVersion -isnot [long]) -or
        $Manifest.schemaVersion -ne 1 -or $Manifest.kind -cne 'layer-app-file-pair') { throw 'Unsupported patch manifest format.' }
    $files = @($Manifest.files)
    if ($files.Count -ne 2) { throw 'A patch manifest must contain exactly two app files.' }
    foreach ($relative in $script:AllowedFiles) {
        $matches = @($files | Where-Object { $null -ne $_.PSObject.Properties['path'] -and $_.path -ceq $relative })
        if ($matches.Count -ne 1) { throw "Missing, duplicate or invalid manifest file entry: $relative" }
        $entry = $matches[0]
        if ($null -eq $entry.PSObject.Properties['original'] -or $null -eq $entry.PSObject.Properties['patched']) { throw 'Missing original or patched identity.' }
        Assert-AppIdentityShape $entry.original
        Assert-AppIdentityShape $entry.patched
        if (Test-AppIdentity $entry.original $entry.patched) { throw "Original and patched files are identical: $relative" }
    }
}

function Read-AppJson {
    param([string]$Path)
    $full = Assert-AppPlainPath $Path
    if ((Get-Item -LiteralPath $full).Length -gt 1048576) { throw "JSON metadata exceeds the size limit: $full" }
    try { return (Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Cannot read JSON metadata '$full': $($_.Exception.Message)" }
}

function Read-AppPatchManifest {
    param([string]$Path)
    $manifest = Read-AppJson $Path
    Assert-AppPatchManifest $manifest
    return $manifest
}

function Write-AppJson {
    param([string]$Path, $Value, [switch]$CreateNew, [ValidateRange(1, 100)][int]$Depth = 12)
    $full = Assert-AppPlainPath $Path -AllowMissing
    $parent = Get-AppDirectory ([IO.Path]::GetDirectoryName($full))
    if ($CreateNew -and [IO.File]::Exists($full)) { throw "Refusing to overwrite metadata: $full" }
    $temporary = [IO.Path]::Combine($parent, '.app-patch-metadata-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth $Depth), $encoding)
        if ($CreateNew -or -not [IO.File]::Exists($full)) { [IO.File]::Move($temporary, $full) }
        else { Invoke-AppFileReplace $temporary $full }
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Invoke-AppNativeReplace {
    param([string]$Source, [string]$Destination, [string]$Backup)
    [IO.File]::Replace($Source, $Destination, $Backup)
}

function New-AppOperationException {
    param([string]$Message, [Exception]$InnerException, [string]$Operation, [string]$Source, [string]$Destination)
    $failure = New-Object InvalidOperationException($Message, $InnerException)
    # Preserve structured evidence through the pair/apply/restore wrappers.
    if ($null -ne $InnerException) {
        foreach ($key in $InnerException.Data.Keys) { $failure.Data[$key] = $InnerException.Data[$key] }
    }
    if ($Operation) {
        $chain = @()
        $cursor = $InnerException
        $nativeCode = $null
        while ($null -ne $cursor) {
            $code = $null
            if ($cursor -is [ComponentModel.Win32Exception]) { $code = $cursor.NativeErrorCode }
            elseif (($cursor.HResult -band 0x7fff0000) -eq 0x00070000) { $code = $cursor.HResult -band 0xffff }
            if ($null -ne $code) { $nativeCode = $code }
            $chain += [pscustomobject]@{ type = $cursor.GetType().FullName; message = $cursor.Message; hresult = $cursor.HResult; nativeErrorCode = $code }
            $cursor = $cursor.InnerException
        }
        $failure.Data['AppFileOperation'] = [pscustomobject]@{
            operation = $Operation; source = $Source; destination = $Destination
            nativeErrorCode = $nativeCode; hresult = $InnerException.HResult; exceptionChain = $chain
        }
    }
    return $failure
}

function Initialize-AppStageFileAccess {
    if ('CodexUsage.PatchStageFilesV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CodexUsage {
    public static class PatchStageFilesV1 {
        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES security, uint disposition, uint flags, IntPtr template);
        public static FileStream CreateNew(string path, string userSid) {
            IntPtr descriptor = IntPtr.Zero;
            uint size;
            // A new sibling must remain writable/deletable even when its parent
            // only grants inherited read access. Never broaden the parent ACL.
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor("D:P(A;;FA;;;" + userSid + ")", 1, out descriptor, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                var attributes = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), lpSecurityDescriptor = descriptor, bInheritHandle = false };
                var handle = CreateFile(path, 0xc0000000, 0, ref attributes, 1, 0x80, IntPtr.Zero);
                if (handle.IsInvalid) {
                    int error = Marshal.GetLastWin32Error();
                    handle.Dispose();
                    throw new Win32Exception(error);
                }
                try { return new FileStream(handle, FileAccess.ReadWrite, 1048576, false); }
                catch (Exception error) {
                    handle.Dispose();
                    // CREATE_NEW succeeded, so this path belongs to this call.
                    try { File.Delete(path); }
                    catch (Exception cleanup) { error.Data["AppStageCleanupError"] = cleanup.Message; error.Data["AppStageCleanupPath"] = path; }
                    throw;
                }
            }
            finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }
    }
}
'@
}

function Copy-AppStagedFile {
    param([string]$Source, [string]$Destination, $Identity)
    $created = $false
    $output = $null
    $input = $null
    $sid = $null
    $operation = 'validate-stage-source'
    try {
        Assert-AppIdentity $Source $Identity
        $destinationFull = Assert-AppPlainPath $Destination -AllowMissing
        [void](Get-AppDirectory ([IO.Path]::GetDirectoryName($destinationFull)))
        $operation = 'create-stage-file'
        Initialize-AppStageFileAccess
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # CREATE_NEW is the no-clobber boundary; do not track/delete a collision.
        $output = [CodexUsage.PatchStageFilesV1]::CreateNew($destinationFull, $sid)
        $created = $true
        $operation = 'copy-stage-stream'
        $input = [IO.File]::OpenRead($Source)
        $input.CopyTo($output, 1048576)
        $output.Flush($true)
        $input.Dispose(); $input = $null
        $output.Dispose(); $output = $null
        $operation = 'verify-stage-file'
        Assert-AppIdentity $destinationFull $Identity
    }
    catch {
        $failure = New-AppOperationException "File operation '$operation' failed from '$Source' to '$Destination': $($_.Exception.Message)" $_.Exception $operation $Source $Destination
        if ($operation -eq 'create-stage-file') {
            # Observation is diagnostic only; never replace the primary error.
            try {
                $failure.Data['AppFileOperation'] | Add-Member -NotePropertyName creation -NotePropertyValue ([pscustomobject]@{
                    currentSid = $sid; requestedSddl = $(if ($sid) { 'D:P(A;;FA;;;' + $sid + ')' } else { $null })
                    desiredAccess = 'GENERIC_READ|GENERIC_WRITE'; disposition = 'CREATE_NEW'
                    sourceState = Get-AppPathObservation $Source; destinationState = Get-AppPathObservation $Destination
                })
            }
            catch { }
        }
        if ($null -ne $input) {
            try { $input.Dispose() } catch { Write-AppCleanupWarning 'close-stage-source' $Source $_.Exception }
            $input = $null
        }
        if ($null -ne $output) {
            try { $output.Dispose() } catch { Write-AppCleanupWarning 'close-stage-destination' $Destination $_.Exception }
            $output = $null
        }
        if ($created) {
            try { [void](Assert-AppPlainPath $destinationFull); [IO.File]::Delete($destinationFull) }
            catch { $failure.Data['AppStageCleanupError'] = $_.Exception.Message; Write-AppCleanupWarning 'cleanup-stage-file' $destinationFull $_.Exception }
        }
        $failure.Data['AppCleanupErrors'] = @(Get-AppOperationWarnings)
        throw $failure
    }
    finally {
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $output) { $output.Dispose() }
    }
}

function Invoke-AppFileReplace {
    param([string]$Source, [string]$Destination)
    [void](Assert-AppPlainPath $Source)
    [void](Assert-AppPlainPath $Destination)
    # PowerShell can coerce $null to an empty string for File.Replace's backup path.
    # A real sibling path is portable across Windows PowerShell 5.1 and PowerShell 7.
    $replaced = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Destination), '.app-patch-replaced-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { Invoke-AppNativeReplace $Source $Destination $replaced }
    catch {
        $replacementError = New-AppOperationException "File replacement failed from '$Source' to '$Destination': $($_.Exception.Message)" $_.Exception 'replace-file' $Source $Destination
        # Win32 ReplaceFile error 1177 can leave Destination missing after
        # moving its old bytes to Backup. Never delete that surviving copy.
        if ([IO.File]::Exists($replaced)) {
            try {
                [void](Assert-AppPlainPath $replaced)
                [void](Assert-AppPlainPath $Destination -AllowMissing)
                if (-not [IO.File]::Exists($Destination) -and -not [IO.Directory]::Exists($Destination)) {
                    [IO.File]::Move($replaced, $Destination)
                }
                else { Write-AppCleanupWarning 'retain-replacement-snapshot' $replaced (New-Object IO.IOException('Replacement failed while destination still exists; retained the original snapshot.')) }
            }
            catch { Write-AppCleanupWarning 'recover-replacement-snapshot' $replaced $_.Exception }
        }
        $replacementError.Data['AppCleanupErrors'] = @(Get-AppOperationWarnings)
        throw $replacementError
    }
    # Only a successful replacement permits deleting its tracked old snapshot.
    try {
        if ([IO.File]::Exists($replaced)) {
            [void](Assert-AppPlainPath $replaced)
            [IO.File]::Delete($replaced)
        }
    }
    catch {
        Write-AppCleanupWarning 'cleanup-replacement-snapshot' $replaced $_.Exception
    }
}

function Assert-AppNotRunning {
    param([string]$AppDir)
    $expected = Get-AppPairPath $AppDir 'ChatGPT.exe'
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop) }
    catch { throw "Cannot verify whether the target application is running: $($_.Exception.Message)" }
    foreach ($process in $processes) {
        if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
            throw "Cannot inspect the executable path of ChatGPT.exe PID $($process.ProcessId); no files were replaced."
        }
        if ((Get-AppFullPath $process.ExecutablePath).Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The target ChatGPT.exe is running (PID $($process.ProcessId)). Close that app before retrying."
        }
    }
}

function Enter-AppPatchLock {
    param([string]$AppDir)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($AppDir.ToUpperInvariant()))).Replace('-', '') }
    finally { $algorithm.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\CodexAppPairPatch-' + $digest))
    try {
        $owned = $false
        try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another patch or restore operation is already running for this app directory.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Exit-AppPatchLock {
    param($Mutex)
    if ($null -ne $Mutex) { try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() } }
}

function Get-AppPairStates {
    param([string]$AppDir, $Manifest)
    $states = @()
    foreach ($entry in @($Manifest.files)) {
        $path = Get-AppPairPath $AppDir $entry.path
        $actual = Get-AppIdentity $path
        $state = 'unknown'
        if (Test-AppIdentity $actual $entry.original) { $state = 'original' }
        elseif (Test-AppIdentity $actual $entry.patched) { $state = 'patched' }
        $states += [pscustomobject]@{ path = $entry.path; state = $state; actual = $actual }
    }
    return $states
}

function Copy-AppVerifiedFile {
    param([string]$Source, [string]$Destination, $Identity)
    $operation = 'validate-copy-source'
    try {
        Assert-AppIdentity $Source $Identity
        $destinationFull = Assert-AppPlainPath $Destination -AllowMissing
        [void](Get-AppDirectory ([IO.Path]::GetDirectoryName($destinationFull)))
        $operation = 'copy-file'
        [IO.File]::Copy($Source, $destinationFull, $false)
        $operation = 'verify-copy-file'
        Assert-AppIdentity $destinationFull $Identity
    }
    catch { throw (New-AppOperationException "File operation '$operation' failed from '$Source' to '$Destination': $($_.Exception.Message)" $_.Exception $operation $Source $Destination) }
}

function Invoke-AppPairReplacement {
    param([Parameter(Mandatory = $true)][array]$Entries)
    $temporaryFiles = New-Object 'Collections.Generic.List[string]'
    $staged = @()
    $pairFailure = $null
    try {
        foreach ($entry in $Entries) {
            Assert-AppIdentity $entry.destination $entry.oldIdentity
            $stage = [IO.Path]::Combine([IO.Path]::GetDirectoryName($entry.destination), '.app-patch-stage-' + [guid]::NewGuid().ToString('N') + '.tmp')
            Copy-AppStagedFile $entry.newSource $stage $entry.newIdentity
            $temporaryFiles.Add($stage)
            $staged += [pscustomobject]@{ entry = $entry; stage = $stage }
        }
        try {
            foreach ($item in $staged) {
                Assert-AppIdentity $item.entry.destination $item.entry.oldIdentity
                Invoke-AppFileReplace $item.stage $item.entry.destination
                Assert-AppIdentity $item.entry.destination $item.entry.newIdentity
            }
        }
        catch {
            $failure = $_.Exception
            $rollbackErrors = @()
            for ($i = $Entries.Count - 1; $i -ge 0; $i--) {
                $entry = $Entries[$i]
                try {
                    $current = Get-AppIdentity $entry.destination
                    if (Test-AppIdentity $current $entry.oldIdentity) { continue }
                    if (-not (Test-AppIdentity $current $entry.newIdentity)) { throw "Unexpected file identity; refusing to overwrite: $($entry.destination)" }
                    $rollback = [IO.Path]::Combine([IO.Path]::GetDirectoryName($entry.destination), '.app-patch-rollback-' + [guid]::NewGuid().ToString('N') + '.tmp')
                    Copy-AppStagedFile $entry.oldSource $rollback $entry.oldIdentity
                    $temporaryFiles.Add($rollback)
                    Invoke-AppFileReplace $rollback $entry.destination
                    Assert-AppIdentity $entry.destination $entry.oldIdentity
                }
                catch { $rollbackErrors += $_.Exception.Message }
            }
            $message = "Replacement failed: $($failure.Message). "
            if ($rollbackErrors.Count -eq 0) { $message += 'The pre-operation file pair was restored.' }
            else { $message += 'RECOVERY REQUIRED: rollback could not finish. Keep the backup and close the app. ' + ($rollbackErrors -join ' | ') }
            $exception = New-AppOperationException $message $failure
            $exception.Data['RecoveryRequired'] = ($rollbackErrors.Count -gt 0)
            $exception.Data['AppRollbackErrors'] = $rollbackErrors
            throw $exception
        }
    }
    catch { $pairFailure = $_.Exception; throw }
    finally {
        foreach ($temporary in $temporaryFiles) {
            try {
                if ([IO.File]::Exists($temporary)) { [void](Assert-AppPlainPath $temporary); [IO.File]::Delete($temporary) }
            }
            catch { Write-AppCleanupWarning 'cleanup-stage-file' $temporary $_.Exception }
        }
        if ($null -ne $pairFailure) { $pairFailure.Data['AppCleanupErrors'] = @(Get-AppOperationWarnings) }
    }
}

Export-ModuleMember -Function *-App*
