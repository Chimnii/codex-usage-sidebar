Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'patcher/AppPatch.Common.psm1') -DisableNameChecking

function Get-UsageCopyProfiles {
    param($Settings)
    $electron = Get-AppDirectory (Join-Path $Settings.appData 'Codex')
    $web = Get-AppDirectory (Join-Path $electron 'web/Codex')
    return [pscustomobject]@{
        electronUserData = $electron; webProfile = $web
        codexHome = (Get-AppDirectory $Settings.codexHome)
    }
}

function Get-UsageCopyTree {
    param([string]$Root, [switch]$IncludeDirectories)
    $rootPath = Get-AppDirectory $Root
    $queue = New-Object 'Collections.Generic.Queue[string]'
    $queue.Enqueue($rootPath)
    while ($queue.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $queue.Dequeue() -Force | Sort-Object Name)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked app/runtime files are unsupported: $($item.FullName)" }
            if ($item.PSIsContainer) {
                $queue.Enqueue($item.FullName)
                # Directory timestamps can settle after a writer closes a child.
                # Membership is verified by the complete path list instead.
                if ($IncludeDirectories) { [pscustomobject]@{ path = $item.FullName.Substring($rootPath.Length + 1).Replace('\', '/'); isDirectory = $true; length = 0; modified = 0 } }
            }
            else {
                [pscustomobject]@{
                    path = $item.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
                    isDirectory = $false; length = [long]$item.Length; modified = $item.LastWriteTimeUtc.Ticks
                }
            }
        }
    }
}

function Get-UsageCopyRevision {
    param([string]$ProjectRoot, $Settings)
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($relative in @('scripts', 'patcher', 'tweak', 'collector', '.local/layer-runtime')) {
        $root = Join-Path $ProjectRoot $relative
        foreach ($entry in @(Get-UsageCopyTree $root | Sort-Object path)) {
            $hash = (Get-AppIdentity (Join-Path $root $entry.path)).sha256
            $lines.Add($relative + '/' + $entry.path + ':' + $hash)
        }
    }
    foreach ($key in @('nodePath','agyPath','codexHome','userProfile','appData','localAppData','userSid')) { $lines.Add($key + ':' + $Settings.$key) }
    $claudeCredentialsPath = if ($Settings.PSObject.Properties['claudeCredentialsPath']) { [string]$Settings.claudeCredentialsPath } else { Join-Path $Settings.userProfile '.claude/.credentials.json' }
    $lines.Add('claudeCredentialsPath:' + $claudeCredentialsPath)
    $lines.Add('claudeEnabled:' + $(if ($Settings.PSObject.Properties['claudeEnabled']) { [string]$Settings.claudeEnabled } else { 'True' }))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Copy-UsageAppTree {
    param([string]$Source, [string]$Destination)
    $sourceRoot = Get-AppDirectory $Source
    $destinationRoot = Assert-AppPlainPath $Destination -AllowMissing
    Assert-AppSeparatePaths $sourceRoot $destinationRoot
    if (Test-Path -LiteralPath $destinationRoot) { throw 'Copy destination must be new.' }
    $entries = @(Get-UsageCopyTree $sourceRoot -IncludeDirectories | Sort-Object path)
    [void][IO.Directory]::CreateDirectory($destinationRoot)
    $receipt = New-Object 'Collections.Generic.List[object]'
    foreach ($entry in $entries) {
        $from = Join-Path $sourceRoot $entry.path
        $to = Join-Path $destinationRoot $entry.path
        if ($entry.isDirectory) { [void][IO.Directory]::CreateDirectory($to); continue }
        # Copy bytes into a user-owned directory, never the Store file permissions.
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to))
        $before = Get-AppIdentity $from
        [IO.File]::Copy($from, $to, $false)
        $copied = Get-AppIdentity $to
        if (-not (Test-AppIdentity $copied $before)) { throw "Copy verification failed: $($entry.path)" }
        $receipt.Add([pscustomobject]@{ path = $entry.path; sha256 = $copied.sha256; length = $copied.length })
    }
    $after = @(Get-UsageCopyTree $sourceRoot -IncludeDirectories | Sort-Object path)
    if (($entries | ConvertTo-Json -Compress) -cne ($after | ConvertTo-Json -Compress)) { throw 'Installed app changed while copying. Retry after its update finishes.' }
    return $receipt.ToArray()
}

function Read-UsageCopyCurrent {
    param([string]$ProjectRoot, [ValidateSet('current','previous')][string]$Name = 'current')
    $base = Join-Path $ProjectRoot '.local/copy'
    $pointer = Join-Path $base ($Name + '.json')
    if (-not [IO.File]::Exists($pointer)) { return $null }
    $value = Read-AppJson $pointer
    if ($value.schemaVersion -notin @(1,2) -or $value.kind -cne 'usage-shared-profile-copy') { throw 'Invalid copy metadata.' }
    if ($value.schemaVersion -eq 1) {
        if ((Split-Path (Get-AppFullPath $value.buildDir) -Parent) -ine (Get-AppFullPath (Join-Path $base 'builds'))) { throw 'Copy build is outside the managed builds directory.' }
    } else {
        $slot = if ($Name -eq 'current') { 'active' } else { 'previous' }
        if ((Get-AppFullPath $value.buildDir) -ine (Get-AppFullPath (Join-Path $base $slot))) { throw 'Copy metadata does not point to the fixed slot.' }
    }
    $expectedApp = Join-Path $value.buildDir 'app'
    if ((Get-AppFullPath $value.appDir) -ine (Get-AppFullPath $expectedApp)) { throw 'Copy app path does not match its build.' }
    if ((Get-AppFullPath $value.layerRoot) -ine (Get-AppFullPath (Join-Path $value.buildDir 'layer-data'))) { throw 'Copy runtime path does not match its build.' }
    [void](Get-AppDirectory $value.appDir)
    return $value
}

function Convert-UsageCopyLocation {
    param($Copy, [string]$Root)
    $value = $Copy | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $old = [string]$value.buildDir
    foreach ($key in @('appDir','layerRoot','manifestPath','backupDir')) {
        if (-not (Test-AppPathInside $value.$key $old)) { throw "Invalid copy receipt path: $key" }
        $value.$key = Join-Path $Root $value.$key.Substring($old.Length + 1)
    }
    $value.buildDir = $Root
    return $value
}

function Remove-UsageCopyDirectory {
    param([string]$ProjectRoot, [string]$Path)
    $base = Get-AppFullPath (Join-Path $ProjectRoot '.local/copy')
    $full = Assert-AppPlainPath $Path -AllowMissing
    $parent = Split-Path $full -Parent
    if (($full -in @((Join-Path $base 'staging'),(Join-Path $base 'retired'))) -or $parent -ieq (Join-Path $base 'builds')) {
        if (-not (Test-Path -LiteralPath $full)) { return }
        # Validate all descendants and the resolved boundary before recursive deletion.
        $null = @(Get-UsageCopyTree $full)
        foreach ($process in @(Get-UsageCopyBlockers)) {
            if (-not $process.ExecutablePath) { throw 'A desktop process has an unknown path; copy cleanup deferred.' }
            if (Test-AppPathInside $process.ExecutablePath $full) { throw "Running copy is protected: $full" }
        }
        Remove-Item -LiteralPath $full -Recurse -Force
    } else { throw "Refusing to remove an unmanaged copy path: $full" }
}

function Assert-UsageCopySlotStopped {
    param([string]$Root)
    $full = Assert-AppPlainPath $Root -AllowMissing
    foreach ($process in @(Get-UsageCopyBlockers)) {
        if (-not $process.ExecutablePath) { throw 'A desktop process has an unknown path.' }
        if (Test-AppPathInside $process.ExecutablePath $full) { throw "The target ChatGPT.exe is running. Close that app before replacing this slot: $full" }
    }
}

function Invoke-UsageCopyCleanup {
    param([string]$ProjectRoot)
    $base = Join-Path $ProjectRoot '.local/copy'
    $keep = @()
    foreach ($name in @('current','previous')) { $c = Read-UsageCopyCurrent $ProjectRoot $name; if ($c) { $keep += $c.buildDir } }
    $candidates = @()
    $builds = Join-Path $base 'builds'
    if (Test-Path -LiteralPath $builds) { $candidates += @(Get-ChildItem -LiteralPath $builds -Directory -Force | Select-Object -ExpandProperty FullName) }
    $candidates += (Join-Path $base 'retired')
    $deferred = @()
    foreach ($path in $candidates) {
        if ($path -in $keep) { continue }
        try { Remove-UsageCopyDirectory $ProjectRoot $path }
        catch { $deferred += [pscustomobject]@{ path=$path; reason=$_.Exception.Message } }
    }
    Write-AppJson (Join-Path $base 'cleanup.json') ([pscustomobject]@{ at=[DateTime]::UtcNow.ToString('o'); deferred=$deferred })
}

function Complete-UsageCopyActivation {
    param([string]$ProjectRoot)
    $base = Join-Path $ProjectRoot '.local/copy'
    $journalPath = Join-Path $base 'activation.json'
    if (-not [IO.File]::Exists($journalPath)) { return }
    $journal = Read-AppJson $journalPath
    $active = Join-Path $base 'active'; $previous = Join-Path $base 'previous'; $retired = Join-Path $base 'retired'
    # Never recover by renaming a directory that may host a running process.
    Assert-UsageCopySlotStopped $active
    Assert-UsageCopySlotStopped $previous
    Assert-UsageCopySlotStopped $retired
    $activeCopy = if ([IO.File]::Exists((Join-Path $active 'copy.json'))) { Read-AppJson (Join-Path $active 'copy.json') } else { $null }
    if ($activeCopy -and $activeCopy.generation -ceq $journal.next.generation) {
        $next = Convert-UsageCopyLocation $activeCopy $active
        Assert-UsageCopyPair $next
        Write-AppJson (Join-Path $active 'copy.json') $next
        Write-AppJson (Join-Path $base 'current.json') $next
        if ($journal.old) {
            $old = $journal.old
            if ($old.schemaVersion -eq 2) {
                $old = Convert-UsageCopyLocation $old $previous
                Assert-UsageCopyPair $old
                Write-AppJson (Join-Path $previous 'copy.json') $old
            }
            Write-AppJson (Join-Path $base 'previous.json') $old
        }
    } else {
        # A crash before the new slot became active restores the complete old slot.
        if ($journal.old -and $journal.old.schemaVersion -eq 2) {
            if (-not [IO.Directory]::Exists($active) -and [IO.Directory]::Exists($previous)) {
                [void](Assert-AppPlainPath $previous); [void](Assert-AppPlainPath $active -AllowMissing)
                Move-Item -LiteralPath $previous -Destination $active
            }
            $old = Convert-UsageCopyLocation $journal.old $active
            Assert-UsageCopyPair $old
            Write-AppJson (Join-Path $active 'copy.json') $old
            Write-AppJson (Join-Path $base 'current.json') $old
        }
        if ([IO.Directory]::Exists($retired) -and -not [IO.Directory]::Exists($previous)) {
            [void](Assert-AppPlainPath $retired); [void](Assert-AppPlainPath $previous -AllowMissing)
            Move-Item -LiteralPath $retired -Destination $previous
        }
    }
    Remove-Item -LiteralPath $journalPath
}

function Publish-UsageCopy {
    param([string]$ProjectRoot, $Copy, $Old)
    $base = Join-Path $ProjectRoot '.local/copy'
    $active = Assert-AppPlainPath (Join-Path $base 'active') -AllowMissing
    $previous = Assert-AppPlainPath (Join-Path $base 'previous') -AllowMissing
    $retired = Assert-AppPlainPath (Join-Path $base 'retired') -AllowMissing
    $stage = Assert-AppPlainPath (Join-Path $base 'staging')
    if ($Copy.buildDir -ine $stage) { throw 'Only the verified staging slot can be activated.' }
    Assert-UsageCopyPair $Copy
    Assert-UsageCopySlotStopped $active
    if ($Old -and $Old.schemaVersion -eq 2) { Assert-UsageCopyPair $Old }
    Remove-UsageCopyDirectory $ProjectRoot $retired
    Write-AppJson (Join-Path $base 'activation.json') ([pscustomobject]@{ old=$Old; next=$Copy })
    if ([IO.Directory]::Exists($previous)) { Assert-UsageCopySlotStopped $previous; Move-Item -LiteralPath $previous -Destination $retired }
    if ([IO.Directory]::Exists($active)) { Move-Item -LiteralPath $active -Destination $previous }
    Move-Item -LiteralPath $stage -Destination $active
    Complete-UsageCopyActivation $ProjectRoot
    Invoke-UsageCopyCleanup $ProjectRoot
    return Read-UsageCopyCurrent $ProjectRoot
}

function Assert-UsageCopyPair {
    param($Copy)
    if (@($Copy.patched).Count -ne 2) { throw 'Invalid patched pair in copy metadata.' }
    foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) {
        $entry = @($Copy.patched | Where-Object path -CEQ $relative)
        if ($entry.Count -ne 1) { throw 'Incomplete patched pair in copy metadata.' }
        Assert-AppIdentity (Get-AppPairPath $Copy.appDir $relative) $entry[0].identity
    }
}

function Get-UsageCopyBlockers {
    # Independent Codex CLI processes may legitimately share CODEX_HOME. Desktop
    # renderers/browser processes may not concurrently own this Chromium profile.
    return @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" -ErrorAction Stop |
        Select-Object ProcessId, ExecutablePath)
}

function Assert-UsageCopyStopped {
    $running = @(Get-UsageCopyBlockers)
    if ($running.Count) { throw "Close ChatGPT / Codex completely before starting the shared-profile copy. $($running.Count) desktop processes are still running. No process was stopped." }
}

function New-UsageCopyStartInfo {
    param($Copy, $Settings, [string]$LaunchId)
    $profiles = Get-UsageCopyProfiles $Settings
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $Copy.appDir 'ChatGPT.exe'
    $start.WorkingDirectory = $Copy.appDir
    $start.UseShellExecute = $false
    # Keep the interactive application visible. Only the verification helper is hidden.
    $start.Arguments = ''
    foreach ($key in @('ELECTRON_RUN_AS_NODE','NODE_OPTIONS','NODE_PATH','CODEX_ELECTRON_USER_DATA_PATH','CODEX_ELECTRON_AGENT_RUN_ID','CODEXPP_REMOTE_DEBUG_PORT','SIDEBAR_USAGE_DEMO_RUNTIME_CACHE')) {
        [void]$start.EnvironmentVariables.Remove($key)
    }
    $values = @{
        APPDATA = $Settings.appData; LOCALAPPDATA = $Settings.localAppData
        USERPROFILE = $Settings.userProfile; CODEX_HOME = $profiles.codexHome
        CODEX_PLUSPLUS_HOME = $Copy.layerRoot; CODEX_PLUSPLUS_USER_ROOT = $Copy.layerRoot
        CODEX_PLUSPLUS_RUNTIME = (Join-Path $Copy.layerRoot 'runtime'); CODEXPP_REMOTE_DEBUG = '0'
        SIDEBAR_USAGE_VERIFY = '1'; SIDEBAR_USAGE_LAUNCH_ID = $LaunchId
        SIDEBAR_USAGE_PACKAGE = $Copy.packageFullName
    }
    foreach ($key in $values.Keys) { $start.EnvironmentVariables[$key] = [string]$values[$key] }
    # Do not set CODEX_ELECTRON_USER_DATA_PATH: in the current app that also
    # changes single-instance behavior. Normal APPDATA selects the original
    # Codex profile and its web/Codex profile, exactly as in the installed app.
    return $start
}

Export-ModuleMember -Function *-UsageCopy*, Copy-UsageAppTree
