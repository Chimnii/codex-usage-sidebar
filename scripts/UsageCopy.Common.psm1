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
            # Documentation, tests and release packaging do not change the copy.
            # Runtime assets remain included, including Layer's loader source.
            if ($entry.path -match '(?i)(^|/)(tests?|docs)(/|$)|\.md$|\.(test|spec)\.[^/]+$|(^|/)(README|CHANGELOG|CONTRIBUTING|LICENSE|NOTICE)(\.[^/]+)?$' -or
                ($relative -eq 'scripts' -and $entry.path -in @('test.cjs','Test-Windows.ps1','package-release.cjs','Doctor.ps1'))) { continue }
            $hash = (Get-AppIdentity (Join-Path $root $entry.path)).sha256
            $lines.Add($relative + '/' + $entry.path + ':' + $hash)
        }
    }
    foreach ($key in @('nodePath','agyPath','codexHome','userProfile','appData','localAppData','userSid')) { $lines.Add($key + ':' + $Settings.$key) }
    $claudeCredentialsPath = if ($Settings.PSObject.Properties['claudeCredentialsPath']) { [string]$Settings.claudeCredentialsPath } else { Join-Path $Settings.userProfile '.claude/.credentials.json' }
    $lines.Add('claudeCredentialsPath:' + $claudeCredentialsPath)
    $lines.Add('claudeEnabled:' + $(if ($Settings.PSObject.Properties['claudeEnabled']) { [string]$Settings.claudeEnabled } else { 'True' }))
    if ($Settings.PSObject.Properties['usage']) { $lines.Add('usage:' + ($Settings.usage | ConvertTo-Json -Depth 16 -Compress)) }
    foreach ($relative in @('package.json','assets/loader.cjs','packages/loader/loader.cjs','packages/installer/assets/loader.cjs')) {
        $file = Join-Path (Join-Path $ProjectRoot '.local/layer-source') $relative
        if ([IO.File]::Exists($file)) { $lines.Add('layer-source/' + $relative + ':' + (Get-AppIdentity $file).sha256) }
    }
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
    param([string]$ProjectRoot, [ValidateSet('current','previous')][string]$Name = 'current', [switch]$AllowMissingSlot)
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
    if ($AllowMissingSlot) { [void](Assert-AppPlainPath $value.appDir -AllowMissing) }
    else { [void](Get-AppDirectory $value.appDir) }
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
    if (($full -in @((Join-Path $base 'staging'),(Join-Path $base 'retired'),(Join-Path $base 'damaged'))) -or $parent -ieq (Join-Path $base 'builds')) {
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
    if ($journal.PSObject.Properties['operation'] -and $journal.operation -ceq 'repair') {
        Complete-UsageCopyRepair $ProjectRoot $journal
        return
    }
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

function Complete-UsageCopyRepair {
    param([string]$ProjectRoot, $Journal)
    $base = Get-AppFullPath (Join-Path $ProjectRoot '.local/copy')
    $active = Assert-AppPlainPath (Join-Path $base 'active') -AllowMissing
    $stage = Assert-AppPlainPath (Join-Path $base 'staging') -AllowMissing
    $damaged = Assert-AppPlainPath (Join-Path $base 'damaged') -AllowMissing
    if ($Journal.next.schemaVersion -ne 2 -or $Journal.next.kind -cne 'usage-shared-profile-copy' -or
        $Journal.next.buildDir -ine $stage -or $Journal.next.appDir -ine (Join-Path $stage 'app') -or
        $Journal.next.layerRoot -ine (Join-Path $stage 'layer-data')) { throw 'Invalid repair staging metadata.' }
    $restored = Convert-UsageCopyLocation $Journal.next $active
    $previous = Read-UsageCopyCurrent $ProjectRoot previous
    if (-not $previous -or $previous.schemaVersion -ne 2 -or $previous.generation -cne $Journal.previousGeneration) { throw 'Repair backup metadata changed.' }
    Assert-UsageCopyPair $previous
    foreach ($slot in @($active,$stage,$damaged,$previous.buildDir)) { Assert-UsageCopySlotStopped $slot }
    $installed = $null
    try { $installed = Read-AppJson (Join-Path $active 'copy.json') } catch { }
    if (-not $installed -or (Get-UsageCopyProperty $installed 'generation') -cne $Journal.next.generation) {
        Assert-UsageCopyPair $Journal.next
        if ([IO.Directory]::Exists($active)) {
            if (Test-Path -LiteralPath $damaged) { throw 'Repair quarantine already exists; refusing to overwrite it.' }
            $null = @(Get-UsageCopyTree $active)
            Move-Item -LiteralPath $active -Destination $damaged
        }
        Move-Item -LiteralPath $stage -Destination $active
    }
    Assert-UsageCopyPair $restored
    Write-AppJson (Join-Path $active 'copy.json') $restored
    Write-AppJson (Join-Path $base 'current.json') $restored
    Write-AppJson (Join-Path $base 'restore-hold.json') ([pscustomobject]@{ generation=$restored.generation })
    Remove-Item -LiteralPath (Join-Path $base 'activation.json')
}

function Repair-UsageCopyFromPrevious {
    param([string]$ProjectRoot, $Copy, $Previous)
    $base = Get-AppFullPath (Join-Path $ProjectRoot '.local/copy')
    $stage = Join-Path $base 'staging'
    if ($Copy.buildDir -ine $stage -or $Previous.buildDir -ine (Join-Path $base 'previous')) { throw 'Repair requires owned staging and previous slots.' }
    Assert-UsageCopyPair $Copy
    Assert-UsageCopyPair $Previous
    Assert-UsageCopySlotStopped (Join-Path $base 'active')
    # Keep one damaged slot for inspection. It never replaces the valid backup.
    Remove-UsageCopyDirectory $ProjectRoot (Join-Path $base 'damaged')
    $Copy.generation = 'repair-' + [guid]::NewGuid().ToString('N')
    Write-AppJson (Join-Path $stage 'copy.json') $Copy
    $journal = [pscustomobject]@{ operation='repair'; next=$Copy; previousGeneration=$Previous.generation }
    Write-AppJson (Join-Path $base 'activation.json') $journal
    Complete-UsageCopyRepair $ProjectRoot $journal
    return Read-UsageCopyCurrent $ProjectRoot
}

function Remove-UsageCopyOldLaunchReports {
    param([string]$ProjectRoot, [ValidateRange(1,1000)][int]$Keep = 20)
    $base = Assert-AppPlainPath (Join-Path $ProjectRoot '.local/copy') -AllowMissing
    $launches = Assert-AppPlainPath (Join-Path $base 'launches') -AllowMissing
    if (-not [IO.Directory]::Exists($launches)) { return }
    $protected = $null
    try {
        $last = Read-AppJson (Join-Path $base 'last-launch.json')
        $candidate = Get-AppFullPath $last.launchPath
        if ((Split-Path $candidate -Parent) -ieq $launches) { $protected = $candidate }
    } catch { }
    $reports = @(Get-ChildItem -LiteralPath $launches -File | Where-Object { $_.Name -match '^\d{8}T\d{9}Z-[a-f0-9]{8}\.json$' } | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($report in @($reports | Select-Object -Skip $Keep)) {
        if ($report.FullName -ieq $protected -or $report.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-10)) { continue }
        $path = Assert-AppPlainPath $report.FullName
        if ((Split-Path $path -Parent) -ine $launches) { throw 'Unexpected launch report location.' }
        Remove-Item -LiteralPath $path -Force
    }
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

function Get-UsageCopyProperty {
    param($Value, [string]$Name, $Default = $null)
    if ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]) { return $Value.$Name }
    return $Default
}

function Get-UsageCopyReadiness {
    param($Launch, $Status, [object[]]$WebProfiles, $CollectorConfig)
    $ui = Get-UsageCopyProperty $Status 'ui'
    $runtime = Get-UsageCopyProperty $Status 'runtime'
    $visiblePanels = Get-UsageCopyProperty $ui 'visiblePanels' 0
    $hiddenBySettings = (Get-UsageCopyProperty $ui 'hiddenBySettings' $false) -eq $true -and
        (Get-UsageCopyProperty $ui 'mountedPanels' 0) -gt 0 -and $visiblePanels -eq 0
    $uiOk = (Get-UsageCopyProperty $ui 'detectorVersion' 0) -eq 2 -and
        (($visiblePanels -gt 0 -and (Get-UsageCopyProperty $ui 'withinSidebar' $false) -eq $true) -or $hiddenBySettings) -and
        (Get-UsageCopyProperty $ui 'snagDetected' $true) -eq $false
    $updated = Get-UsageCopyProperty $Status 'updatedAt'
    $refreshed = $false
    try { $refreshed = $updated -and ([DateTime]$updated).ToUniversalTime() -gt ([DateTime]$Launch.startedAt).ToUniversalTime() } catch { }
    $providers = @(foreach ($id in @('codex','antigravity','claude')) {
        $provider = @(Get-UsageCopyProperty $Status 'providers' @() | Where-Object id -CEQ $id | Select-Object -First 1)
        $enabled = switch ($id) {
            'antigravity' { -not [string]::IsNullOrWhiteSpace([string](Get-UsageCopyProperty $CollectorConfig 'agyPath')) }
            'claude' { -not [string]::IsNullOrWhiteSpace([string](Get-UsageCopyProperty $CollectorConfig 'claudeCredentialsPath')) }
            default { $true }
        }
        $enabledHints = Get-UsageCopyProperty $CollectorConfig 'providerEnabled'
        if ($enabledHints -and $enabledHints.PSObject.Properties[$id] -and $enabledHints.$id -is [bool]) { $enabled = $enabledHints.$id }
        $state = if ($provider.Count) { Get-UsageCopyProperty $provider[0] 'status' 'unknown' } else { 'unknown' }
        if ($state -notin @('ok','stale','unavailable','disconnected')) { $state = 'unknown' }
        [pscustomobject]@{ id=$id; enabled=[bool]$enabled; status=$(if ($enabled) { $state } else { 'disabled' }) }
    })
    return [pscustomobject]@{
        checks = [pscustomobject]@{
            originalRuntimeProfile = @($Launch.profiles.electronUserData,$Launch.profiles.webProfile) -icontains (Get-UsageCopyProperty $runtime 'userData')
            originalWebProfile = @($WebProfiles) -icontains $Launch.profiles.webProfile
            originalCodexHome = (Get-UsageCopyProperty $runtime 'codexHome') -ieq $Launch.profiles.codexHome
            selectedCopy = (Get-UsageCopyProperty $runtime 'executable') -ieq (Join-Path $Launch.appDir 'ChatGPT.exe')
            sidebarPanel = [bool]$uiOk
            # Provider authentication/availability is reported separately. A
            # failed provider must not turn a working app into a failed launch.
            collectorRefresh = (Get-UsageCopyProperty $Status 'cycles' 0) -ge 1 -and
                (Get-UsageCopyProperty $Status 'active' $true) -eq $false -and [bool]$refreshed
        }
        providerHealth = $providers
        refreshObservation = [pscustomobject]@{
            cycles = Get-UsageCopyProperty $Status 'cycles' 0
            intervalMs = Get-UsageCopyProperty $Status 'intervalMs'
        }
    }
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
