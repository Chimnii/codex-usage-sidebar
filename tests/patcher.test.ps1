[CmdletBinding()]
param(
    [string]$ToolDir,
    [string]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ToolDir) { $ToolDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'patcher' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runName = '{0}-ps{1}-{2}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), $PSVersionTable.PSVersion.Major, $PID
$fixtureRoot = Join-Path $workspace ('.local/test-work/patcher-fixture-tests/' + $runName)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
if (-not $EvidencePath) {
    $EvidencePath = Join-Path $workspace ('.local/test-results/patcher-test-results-ps' + $PSVersionTable.PSVersion.Major + '.json')
}
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($EvidencePath))) | Out-Null
$manifestScript = Join-Path $ToolDir 'New-PatchManifest.ps1'
$applyScript = Join-Path $ToolDir 'Apply-AppPatch.ps1'
$restoreScript = Join-Path $ToolDir 'Restore-AppPatch.ps1'
foreach ($scriptPath in @($manifestScript, $applyScript, $restoreScript)) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Missing script: $scriptPath" }
}
$pairPaths = @('resources/app.asar', 'ChatGPT.exe')
$results = New-Object 'System.Collections.Generic.List[object]'
$script:fixtureNumber = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-PairHashes {
    param([string]$AppDir)
    $values = foreach ($relative in $pairPaths) {
        $path = Join-Path $AppDir $relative
        '{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return ($values -join '|')
}

function Get-TreeFingerprint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $entries = foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse | Sort-Object FullName)) {
        $relative = $item.FullName.Substring($root.Length)
        if ($item.PSIsContainer) { 'D:' + $relative }
        else { 'F:{0}:{1}:{2}' -f $relative, $item.Attributes, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash }
    }
    return ($entries -join "`n")
}

function New-Fixture {
    param([string]$Name)
    $script:fixtureNumber++
    $dir = Join-Path $fixtureRoot ('{0:00}-{1}' -f $script:fixtureNumber, $Name)
    $original = Join-Path $dir 'original app'
    $patched = Join-Path $dir 'patched app'
    $target = Join-Path $dir 'target app'
    foreach ($app in @($original, $patched, $target)) {
        [IO.Directory]::CreateDirectory((Join-Path $app 'resources')) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $app 'resources/app.asar'), [Text.Encoding]::UTF8.GetBytes('original-asar-' + $Name))
        [IO.File]::WriteAllBytes((Join-Path $app 'ChatGPT.exe'), [byte[]](0, 5, 16, 32, 127, 128, 255))
        [IO.File]::WriteAllBytes((Join-Path $app 'preserve-me.bin'), [byte[]](91, 92, 93))
    }
    [IO.File]::WriteAllBytes((Join-Path $patched 'resources/app.asar'), [Text.Encoding]::UTF8.GetBytes('patched-asar-' + $Name))
    [IO.File]::WriteAllBytes((Join-Path $patched 'ChatGPT.exe'), [byte[]](1, 6, 17, 33, 126, 129, 254, 7))
    $manifest = Join-Path $dir 'patch-manifest.json'
    $null = & $manifestScript -OriginalAppDir $original -PatchedAppDir $patched -ManifestPath $manifest
    Assert-True (Test-Path -LiteralPath $manifest -PathType Leaf) 'Manifest was not written.'
    return [pscustomobject]@{
        Dir = $dir; Original = $original; Patched = $patched; Target = $target
        Manifest = $manifest; Backups = (Join-Path $dir 'backups')
        OriginalHashes = (Get-PairHashes $original); PatchedHashes = (Get-PairHashes $patched)
    }
}

function Invoke-Apply {
    param($Fixture)
    return (& $applyScript -AppDir $Fixture.Target -PatchedAppDir $Fixture.Patched -ManifestPath $Fixture.Manifest -BackupRoot $Fixture.Backups -Confirm:$false)
}

function Invoke-Restore {
    param($Fixture, [string]$BackupDir)
    return (& $restoreScript -AppDir $Fixture.Target -BackupDir $BackupDir -Confirm:$false)
}

function Expect-Failure {
    param([scriptblock]$Action)
    try { $null = & $Action }
    catch { return $_.Exception.Message }
    throw 'Operation unexpectedly succeeded.'
}

function Run-Case {
    param([string]$Name, [scriptblock]$Action)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Action
        $results.Add([pscustomobject]@{ name = $Name; status = 'passed'; durationMs = $timer.ElapsedMilliseconds; detail = $detail })
        Write-Host ('PASS ' + $Name)
    }
    catch {
        $results.Add([pscustomobject]@{ name = $Name; status = 'failed'; durationMs = $timer.ElapsedMilliseconds; error = $_.Exception.Message; location = $_.ScriptStackTrace })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}

function Set-RestrictiveFixtureSecurity {
    param([string]$AppDir)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    foreach ($dir in @($AppDir, (Join-Path $AppDir 'resources'))) {
        $acl = Get-Acl -LiteralPath $dir
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'None', 'None', 'Allow')))
        Set-Acl -LiteralPath $dir -AclObject $acl
    }
    foreach ($relative in $pairPaths) {
        $path = Join-Path $AppDir $relative
        $acl = Get-Acl -LiteralPath $path
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'None', 'None', 'Allow')))
        Set-Acl -LiteralPath $path -AclObject $acl
    }
}

function Get-FixtureSecurity {
    param([string]$AppDir)
    return (@($AppDir, (Join-Path $AppDir 'resources'), (Join-Path $AppDir 'resources/app.asar'), (Join-Path $AppDir 'ChatGPT.exe'), (Join-Path $AppDir 'preserve-me.bin')) | ForEach-Object { (Get-Acl -LiteralPath $_).Sddl }) -join '|'
}

Run-Case 'apply WhatIf leaves target and backup root untouched' {
    $f = New-Fixture 'apply-dry-run'
    $before = Get-TreeFingerprint $f.Target
    $null = & $applyScript -AppDir $f.Target -PatchedAppDir $f.Patched -ManifestPath $f.Manifest -BackupRoot $f.Backups -WhatIf
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'WhatIf changed target files.'
    Assert-True (-not (Test-Path -LiteralPath $f.Backups)) 'WhatIf created a backup directory.'
}

Run-Case 'backup apply restore preserve exact bytes and unrelated files' {
    $f = New-Fixture 'round-trip'
    $before = Get-TreeFingerprint $f.Target
    $applied = Invoke-Apply $f
    Assert-True ((Get-PairHashes $f.Target) -eq $f.PatchedHashes) 'Apply hashes differ from patched source.'
    Assert-True ([bool]$applied.BackupDir) 'Apply result did not return BackupDir.'
    Assert-True (Test-Path -LiteralPath $applied.BackupDir -PathType Container) 'Backup directory missing.'
    $null = Invoke-Restore $f $applied.BackupDir
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Restore did not recover the original tree byte for byte.'
    return [pscustomobject]@{ fixture = $f.Dir; backupDir = $applied.BackupDir; applyStatus = $applied.Status }
}

Run-Case 'repeated apply and restore are safe and do not replace original backup' {
    $f = New-Fixture 'repeat-safe'
    $first = Invoke-Apply $f
    $backupBefore = Get-TreeFingerprint $f.Backups
    $second = Invoke-Apply $f
    Assert-True ((Get-PairHashes $f.Target) -eq $f.PatchedHashes) 'Second apply changed the expected pair.'
    Assert-True ((Get-TreeFingerprint $f.Backups) -eq $backupBefore) 'Second apply changed or added backups.'
    $null = Invoke-Restore $f $first.BackupDir
    $before = Get-TreeFingerprint $f.Target
    $again = Invoke-Restore $f $first.BackupDir
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Repeated restore changed the target.'
    return [pscustomobject]@{ secondApplyStatus = $second.Status; secondRestoreStatus = $again.Status }
}

Run-Case 'restore WhatIf leaves patched target and backup untouched' {
    $f = New-Fixture 'restore-dry-run'
    $applied = Invoke-Apply $f
    $targetBefore = Get-TreeFingerprint $f.Target
    $backupBefore = Get-TreeFingerprint $f.Backups
    $null = & $restoreScript -AppDir $f.Target -BackupDir $applied.BackupDir -WhatIf
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $targetBefore) 'Restore WhatIf changed target.'
    Assert-True ((Get-TreeFingerprint $f.Backups) -eq $backupBefore) 'Restore WhatIf changed backup.'
}

Run-Case 'changed patched source is rejected before target or backup writes' {
    $f = New-Fixture 'bad-source'
    [IO.File]::WriteAllBytes((Join-Path $f.Patched 'ChatGPT.exe'), [byte[]](9, 9, 9))
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Apply $f }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Rejected source changed target.'
    Assert-True (-not (Test-Path -LiteralPath $f.Backups)) 'Rejected source created backups.'
    return $reason
}

Run-Case 'altered manifest hashes are rejected' {
    $f = New-Fixture 'bad-manifest-hash'
    $originalHash = (Get-FileHash -LiteralPath (Join-Path $f.Original 'resources/app.asar') -Algorithm SHA256).Hash
    $text = [IO.File]::ReadAllText($f.Manifest)
    $changed = [regex]::Replace($text, [regex]::Escape($originalHash), ('f' * 64), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Assert-True ($changed -ne $text) 'Could not locate manifest hash to alter.'
    [IO.File]::WriteAllText($f.Manifest, $changed)
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Apply $f }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Rejected manifest changed target.'
    return $reason
}

Run-Case 'unknown or updated target version is rejected' {
    $f = New-Fixture 'new-version'
    [IO.File]::WriteAllBytes((Join-Path $f.Target 'ChatGPT.exe'), [byte[]](44, 45, 46, 47))
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Apply $f }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Unknown target was modified.'
    Assert-True (-not (Test-Path -LiteralPath $f.Backups)) 'Unknown target created backup.'
    return $reason
}

Run-Case 'mixed target cannot be applied as if pristine' {
    $f = New-Fixture 'mixed-apply'
    Copy-Item -LiteralPath (Join-Path $f.Patched 'resources/app.asar') -Destination (Join-Path $f.Target 'resources/app.asar')
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Apply $f }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Mixed apply changed target.'
    return $reason
}

Run-Case 'corrupt backup cannot overwrite patched app' {
    $f = New-Fixture 'corrupt-backup'
    $applied = Invoke-Apply $f
    $backupAsar = @(Get-ChildItem -LiteralPath $applied.BackupDir -Recurse -File | Where-Object { $_.Name -eq 'app.asar' })
    Assert-True ($backupAsar.Count -eq 1) 'Backup did not have exactly one app.asar.'
    [IO.File]::WriteAllBytes($backupAsar[0].FullName, [byte[]](99, 98, 97))
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Restore $f $applied.BackupDir }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Corrupt backup changed target.'
    return $reason
}

Run-Case 'backup is bound to its original target directory' {
    $f = New-Fixture 'wrong-binding'
    $applied = Invoke-Apply $f
    $other = Join-Path $f.Dir 'other target app'
    Copy-Item -LiteralPath $f.Target -Destination $other -Recurse
    $before = Get-TreeFingerprint $other
    $reason = Expect-Failure { & $restoreScript -AppDir $other -BackupDir $applied.BackupDir -Confirm:$false }
    Assert-True ((Get-TreeFingerprint $other) -eq $before) 'Wrong target was overwritten.'
    return $reason
}

Run-Case 'known original patched mixed pair can be restored' {
    $f = New-Fixture 'mixed-restore'
    $applied = Invoke-Apply $f
    Copy-Item -LiteralPath (Join-Path $f.Original 'resources/app.asar') -Destination (Join-Path $f.Target 'resources/app.asar')
    $null = Invoke-Restore $f $applied.BackupDir
    Assert-True ((Get-PairHashes $f.Target) -eq $f.OriginalHashes) 'Known mixed pair was not restored.'
}

Run-Case 'restore refuses an unknown file after app version changed' {
    $f = New-Fixture 'restore-unknown-version'
    $applied = Invoke-Apply $f
    [IO.File]::WriteAllBytes((Join-Path $f.Target 'ChatGPT.exe'), [byte[]](44, 45, 46, 47))
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Restore $f $applied.BackupDir }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Restore overwrote newer unknown version.'
    return $reason
}

Run-Case 'manifest relative traversal path is rejected' {
    $f = New-Fixture 'path-traversal'
    $text = [IO.File]::ReadAllText($f.Manifest)
    $changed = [regex]::Replace($text, 'resources(?:/|\\\\)app\.asar', '../escape/app.asar')
    Assert-True ($changed -ne $text) 'Could not locate manifest relative path to alter.'
    [IO.File]::WriteAllText($f.Manifest, $changed)
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { Invoke-Apply $f }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Traversal manifest changed target.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $f.Dir 'escape'))) 'Traversal manifest wrote outside target.'
    return $reason
}

Run-Case 'locked second target file causes complete rollback' {
    $f = New-Fixture 'midway-rollback'
    $manifest = Get-Content -Encoding UTF8 -LiteralPath $f.Manifest -Raw | ConvertFrom-Json
    Assert-True ($manifest.files[0].path -eq 'resources/app.asar') 'Fixture does not replace ASAR before the locked EXE.'
    $before = Get-TreeFingerprint $f.Target
    $handle = [IO.File]::Open((Join-Path $f.Target 'ChatGPT.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $reason = Expect-Failure { Invoke-Apply $f } }
    finally { $handle.Dispose() }
    Assert-True ($reason -match 'being used by another process') 'Apply failed for an unexpected reason before testing the sharing violation.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Failed apply left target partly patched.'
    return $reason
}

Run-Case 'read-only target fails safely without changing bytes or attributes' {
    $f = New-Fixture 'read-only'
    $file = Get-Item -LiteralPath (Join-Path $f.Target 'ChatGPT.exe')
    $file.IsReadOnly = $true
    $before = Get-TreeFingerprint $f.Target
    try {
        $reason = Expect-Failure { Invoke-Apply $f }
        Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Read-only failure changed target.'
    }
    finally { (Get-Item -LiteralPath $file.FullName).IsReadOnly = $false }
    return $reason
}

Run-Case 'junction target ancestor is rejected' {
    $f = New-Fixture 'reparse-path'
    $alias = Join-Path $f.Dir 'linked app'
    $null = New-Item -ItemType Junction -Path $alias -Target $f.Target
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { & $applyScript -AppDir $alias -PatchedAppDir $f.Patched -ManifestPath $f.Manifest -BackupRoot $f.Backups -Confirm:$false }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Junction target changed.'
    return $reason
}

Run-Case 'Windows namespace and trailing-dot target aliases are rejected' {
    $f = New-Fixture 'windows-path-aliases'
    $before = Get-TreeFingerprint $f.Target
    $reasons = foreach ($alias in @(('\\?\' + $f.Target), ($f.Target + '.'))) {
        Expect-Failure { & $applyScript -AppDir $alias -PatchedAppDir $f.Patched -ManifestPath $f.Manifest -BackupRoot $f.Backups -Confirm:$false }
    }
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Path alias changed target.'
    Assert-True (-not (Test-Path -LiteralPath $f.Backups)) 'Path alias created backup.'
    return $reasons
}

Run-Case 'relative paths resolve from PowerShell location after Set-Location' {
    $f = New-Fixture 'relative-paths'
    Assert-True ([Environment]::CurrentDirectory -ne $f.Dir) 'Fixture unexpectedly matches the process starting directory.'
    Push-Location -LiteralPath $f.Dir
    try {
        $null = & $manifestScript -OriginalAppDir 'original app' -PatchedAppDir 'patched app' -ManifestPath 'relative-manifest.json'
        Assert-True (Test-Path -LiteralPath (Join-Path $f.Dir 'relative-manifest.json') -PathType Leaf) 'Relative manifest was written outside the PowerShell location.'
        $applied = & $applyScript -AppDir 'target app' -PatchedAppDir 'patched app' -ManifestPath 'relative-manifest.json' -BackupRoot 'relative backups' -Confirm:$false
        Assert-True ((Get-PairHashes $f.Target) -eq $f.PatchedHashes) 'Relative apply did not patch intended target.'
        $relativeBackup = Join-Path 'relative backups' (Split-Path -Leaf $applied.BackupDir)
        $null = & $restoreScript -AppDir 'target app' -BackupDir $relativeBackup -Confirm:$false
        Assert-True ((Get-PairHashes $f.Target) -eq $f.OriginalHashes) 'Relative restore did not recover intended target.'
    }
    finally { Pop-Location }
}

Run-Case 'locked second file during restore rolls back to complete patched pair' {
    $f = New-Fixture 'restore-midway-rollback'
    $applied = Invoke-Apply $f
    $before = Get-TreeFingerprint $f.Target
    $handle = [IO.File]::Open((Join-Path $f.Target 'ChatGPT.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $reason = Expect-Failure { Invoke-Restore $f $applied.BackupDir } }
    finally { $handle.Dispose() }
    Assert-True ($reason -match 'being used by another process') 'Restore failed for an unexpected reason before testing the sharing violation.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Failed restore left target partly original and partly patched.'
    $null = Invoke-Restore $f $applied.BackupDir
    Assert-True ((Get-PairHashes $f.Target) -eq $f.OriginalHashes) 'Restore could not be retried after the lock was released.'
    return $reason
}

Run-Case 'ReplaceFile 1177-style rename then failure restores missing target and preserves recovery backup' {
    $f = New-Fixture 'replacefile-renamed-target'
    $faultTools = Join-Path $f.Dir 'fault-injected-tools'
    Copy-Item -LiteralPath $ToolDir -Destination $faultTools -Recurse
    $modulePath = Join-Path $faultTools 'AppPatch.Common.psm1'
    $source = [IO.File]::ReadAllText($modulePath)
    $needle = '[IO.File]::Replace($Source, $Destination, $Backup)'
    Assert-True (($source.Split(@($needle), [StringSplitOptions]::None).Count - 1) -eq 1) 'Native replacement injection point is not unique.'
    $injection = @'
if ([IO.Path]::GetFileName($Destination) -eq 'ChatGPT.exe') {
    [IO.File]::Move($Destination, $Backup)
    throw 'Synthetic ReplaceFile 1177: destination renamed before replacement failed.'
}
[IO.File]::Replace($Source, $Destination, $Backup)
'@
    [IO.File]::WriteAllText($modulePath, $source.Replace($needle, $injection), (New-Object Text.UTF8Encoding($false)))
    $before = Get-TreeFingerprint $f.Target
    $reason = Expect-Failure { & (Join-Path $faultTools 'Apply-AppPatch.ps1') -AppDir $f.Target -PatchedAppDir $f.Patched -ManifestPath $f.Manifest -BackupRoot $f.Backups -Confirm:$false }
    Assert-True ($reason -match '1177') 'Injected native failure did not occur.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Partial native replacement lost original bytes or left a missing target.'
    $backups = @(Get-ChildItem -LiteralPath $f.Backups -Filter backup-manifest.json -Recurse)
    Assert-True ($backups.Count -eq 1) 'Verified original pair backup was lost.'
    $restored = & (Join-Path $faultTools 'Restore-AppPatch.ps1') -AppDir $f.Target -BackupDir $backups[0].DirectoryName -Confirm:$false
    Assert-True ($restored.status -eq 'already-original') 'Recovery did not recognize exact originals after injected failure.'
    Assert-True ((Get-PairHashes $f.Target) -eq $f.OriginalHashes) 'Recovery changed the original pair.'
    return $reason
}

Run-Case 'restrictive inherited child ACL supports apply restore with exact final security' {
    $f = New-Fixture 'restricted-child-acl'
    Set-RestrictiveFixtureSecurity $f.Target
    $before = Get-TreeFingerprint $f.Target
    $securityBefore = Get-FixtureSecurity $f.Target
    $applied = Invoke-Apply $f
    Assert-True ((Get-PairHashes $f.Target) -eq $f.PatchedHashes) 'Restricted apply did not install expected bytes.'
    Assert-True ((Get-FixtureSecurity $f.Target) -eq $securityBefore) 'Replacement did not preserve exact target/unrelated owner, group and DACL.'
    $null = Invoke-Restore $f $applied.BackupDir
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Restricted restore changed unrelated files or left temporary files.'
    Assert-True ((Get-FixtureSecurity $f.Target) -eq $securityBefore) 'Restore did not preserve exact owner, group and DACL.'
}

Run-Case 'secure stage refuses existing destination without deleting collision' {
    $f = New-Fixture 'stage-collision'
    Import-Module (Join-Path $ToolDir 'AppPatch.Common.psm1') -Force -DisableNameChecking
    $destination = Join-Path $f.Target '.app-patch-stage-collision.tmp'
    [IO.File]::WriteAllText($destination, 'pre-existing independent file')
    $before = Get-TreeFingerprint $f.Target
    $caught = $null
    try { Copy-AppStagedFile (Join-Path $f.Patched 'ChatGPT.exe') $destination (Get-AppIdentity (Join-Path $f.Patched 'ChatGPT.exe')) }
    catch { $caught = $_.Exception }
    Assert-True ($null -ne $caught) 'CREATE_NEW overwrote an existing stage path.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Collision failure deleted or changed an unowned file.'
    Assert-True ($caught.Data['AppFileOperation'].operation -eq 'create-stage-file') 'Collision operation evidence was lost.'
    Assert-True ($caught.Data['AppFileOperation'].nativeErrorCode -in @(80, 183)) 'Collision native error evidence was lost.'
}

Run-Case 'stage create access denial records native code and leaves original tree untouched' {
    $f = New-Fixture 'stage-create-denied'
    Import-Module (Join-Path $ToolDir 'AppPatch.Common.psm1') -Force -DisableNameChecking
    $dir = Join-Path $f.Target 'resources'
    $savedAcl = Get-Acl -LiteralPath $dir
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $restricted = Get-Acl -LiteralPath $dir
    $restricted.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($restricted.Access)) { [void]$restricted.RemoveAccessRuleSpecific($rule) }
    $restricted.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $dir -AclObject $restricted
    $before = Get-TreeFingerprint $f.Target
    try {
        $destination = Join-Path $dir '.app-patch-stage-denied.tmp'
        $caught = $null
        try { Copy-AppStagedFile (Join-Path $f.Patched 'ChatGPT.exe') $destination (Get-AppIdentity (Join-Path $f.Patched 'ChatGPT.exe')) }
        catch { $caught = $_.Exception }
        Assert-True ($null -ne $caught) 'Read-only directory unexpectedly accepted a stage file.'
        Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Failed create changed the target tree.'
        Assert-True ($caught.Data['AppFileOperation'].operation -eq 'create-stage-file') 'Native failure operation evidence was lost.'
        Assert-True ($caught.Data['AppFileOperation'].nativeErrorCode -eq 5) 'Access-denied native code was lost.'
        Assert-True ($caught.Data['AppFileOperation'].destination -eq $destination) 'Failure path evidence was lost.'
        Assert-True ($null -ne $caught.InnerException) 'Native failure inner exception was discarded.'
    }
    finally {
        if (-not ('SidebarTestAcl' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'support/RestoreTestAcl.cs') }
        [SidebarTestAcl]::Restore($dir, $savedAcl.Sddl, $savedAcl.AreAccessRulesProtected)
    }
}

Run-Case 'partial stage stream failure removes only owned new file and preserves structured cause' {
    $f = New-Fixture 'stage-stream-fault'
    $faultTools = Join-Path $f.Dir 'fault-injected-tools'
    Copy-Item -LiteralPath $ToolDir -Destination $faultTools -Recurse
    $modulePath = Join-Path $faultTools 'AppPatch.Common.psm1'
    $source = [IO.File]::ReadAllText($modulePath)
    $needle = '$input.CopyTo($output, 1048576)'
    Assert-True (($source.Split(@($needle), [StringSplitOptions]::None).Count - 1) -eq 1) 'Stream fault point is not unique.'
    $injection = '$output.WriteByte(42); throw (New-Object IO.IOException("Synthetic interrupted staging stream"))'
    [IO.File]::WriteAllText($modulePath, $source.Replace($needle, $injection), (New-Object Text.UTF8Encoding($false)))
    Import-Module $modulePath -Force -DisableNameChecking
    $destination = Join-Path $f.Target '.app-patch-stage-interrupted.tmp'
    $before = Get-TreeFingerprint $f.Target
    $caught = $null
    try { Copy-AppStagedFile (Join-Path $f.Patched 'ChatGPT.exe') $destination (Get-AppIdentity (Join-Path $f.Patched 'ChatGPT.exe')) }
    catch { $caught = $_.Exception }
    Assert-True ($null -ne $caught) 'Injected stream failure did not occur.'
    Assert-True ($caught.Data['AppFileOperation'].operation -eq 'copy-stage-stream') 'Stream failure operation was lost.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Interrupted stage left a partial file or modified other files.'
}

Run-Case 'apply failure retains native replacement context through rollback and wrapper' {
    $f = New-Fixture 'native-context-wrapper'
    Set-RestrictiveFixtureSecurity $f.Target
    $securityBefore = Get-FixtureSecurity $f.Target
    $before = Get-TreeFingerprint $f.Target
    $locked = [IO.File]::Open((Join-Path $f.Target 'ChatGPT.exe'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $caught = $null
    try { $null = Invoke-Apply $f }
    catch { $caught = $_.Exception }
    finally { $locked.Dispose() }
    Assert-True ($null -ne $caught) 'Sharing violation was not observed.'
    Assert-True ($caught.Data['AppFileOperation'].operation -eq 'replace-file') 'Apply wrapper lost native operation context.'
    Assert-True ($caught.Data['AppFileOperation'].nativeErrorCode -eq 32) 'Apply wrapper lost sharing-violation code.'
    Assert-True ($caught.Data['AppFileOperation'].destination -eq (Join-Path $f.Target 'ChatGPT.exe')) 'Apply wrapper lost destination.'
    Assert-True ($null -ne $caught.InnerException) 'Apply wrapper discarded inner exception.'
    Assert-True ($caught.Data['RecoveryRequired'] -eq $false) 'Successful mixed-pair rollback was not recorded.'
    Assert-True ((Get-TreeFingerprint $f.Target) -eq $before) 'Restricted rollback did not recover exact originals.'
    Assert-True ((Get-FixtureSecurity $f.Target) -eq $securityBefore) 'Restricted rollback changed owner/group/DACL or unrelated file access.'
}

Run-Case 'successful replacement cleanup warnings are returned for durable installer logging' {
    $f = New-Fixture 'cleanup-warning-evidence'
    $faultTools = Join-Path $f.Dir 'fault-injected-tools'
    Copy-Item -LiteralPath $ToolDir -Destination $faultTools -Recurse
    $modulePath = Join-Path $faultTools 'AppPatch.Common.psm1'
    $source = [IO.File]::ReadAllText($modulePath)
    $needle = '[IO.File]::Delete($replaced)'
    Assert-True (($source.Split(@($needle), [StringSplitOptions]::None).Count - 1) -eq 1) 'Snapshot cleanup fault point is not unique.'
    $injection = 'throw (New-Object IO.IOException("Synthetic retained snapshot cleanup failure"))'
    [IO.File]::WriteAllText($modulePath, $source.Replace($needle, $injection), (New-Object Text.UTF8Encoding($false)))
    $applied = & (Join-Path $faultTools 'Apply-AppPatch.ps1') -AppDir $f.Target -PatchedAppDir $f.Patched -ManifestPath $f.Manifest -BackupRoot $f.Backups -Confirm:$false
    Assert-True ($applied.status -eq 'applied') 'Cleanup warning incorrectly changed the successful application state.'
    Assert-True ((Get-PairHashes $f.Target) -eq $f.PatchedHashes) 'Cleanup warning changed patched bytes.'
    Assert-True (@($applied.warnings).Count -ge 2) 'Successful cleanup warnings were not included in the result.'
    foreach ($warning in @($applied.warnings)) {
        Assert-True ($warning.operation -eq 'cleanup-replacement-snapshot') 'Cleanup warning operation was lost.'
        Assert-True ([IO.File]::Exists($warning.path)) 'Cleanup warning did not retain the exact recovery path.'
    }
}

$failed = @($results | Where-Object { $_.status -eq 'failed' })
$report = [pscustomobject]@{
    timestamp = [DateTime]::UtcNow.ToString('o')
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    edition = $PSVersionTable.PSEdition
    fixtureRoot = $fixtureRoot
    toolDir = [IO.Path]::GetFullPath($ToolDir)
    toolFiles = @(Get-ChildItem -LiteralPath $ToolDir -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    })
    scope = 'Dedicated arbitrary-byte fixtures only; no real app, profiles, credentials or processes touched.'
    total = $results.Count
    passed = $results.Count - $failed.Count
    failed = $failed.Count
    cases = $results.ToArray()
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($EvidencePath), ($report | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
Write-Host ('Evidence: ' + [IO.Path]::GetFullPath($EvidencePath))
if ($failed.Count -ne 0) { exit 1 }
exit 0
