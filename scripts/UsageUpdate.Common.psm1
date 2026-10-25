Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Invoke-UsageStoreCommand {
    param([ValidateSet('installed','updates','apply')][string]$Action, [int]$TimeoutSeconds = 90)
    $exe = Join-Path $env:LOCALAPPDATA 'Microsoft/WindowsApps/store.exe'
    if (-not [IO.File]::Exists($exe)) { throw 'Microsoft Store CLI (store.exe) is unavailable. Update Microsoft Store first.' }
    # Use the installed package family as update-id. Catalog product IDs fail
    # installed-metadata lookup on Store 22609. Never update all Store apps.
    $arguments = switch ($Action) {
        'installed' { 'installed --filter OpenAI' }
        'updates' { 'updates --filter OpenAI' }
        'apply' { 'update OpenAI.Codex_2p2nqsd0c76g0 --apply' }
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe; $info.Arguments = $arguments
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        # No implicit answers to interactive prompts. --apply is the only
        # installation path, and is never passed by a background check.
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw "Store $Action timed out. Installation completion has not been confirmed."
        }
        $output = $stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or $output -match '(?im)^\s*(?:Error:|Failed\b|Cannot\b)' -or $output -match 'Would you like to|\[y/n\]') {
            throw "Store $Action failed or requested interactive input: $($output.Trim())"
        }
        return $output
    }
    finally { $process.Dispose() }
}

function ConvertFrom-UsageStoreTable {
    param([string]$Text)
    $clean = $Text -replace '\x1b\[[0-9;]*[A-Za-z]', ''
    # The CLI preview has text output. Unknown layouts are errors, not 'no update'.
    $lines = @($clean -split '\r?\n' | Where-Object { $_.TrimStart().StartsWith([string][char]0x2502) })
    $headers = $null
    $rows = @()
    foreach ($line in $lines) {
        $parts = $line.Split([char]0x2502)
        $cells = @($parts[1..($parts.Length - 2)] | ForEach-Object { $_.Trim() })
        if ($null -eq $headers) {
            if ($cells -contains 'Name' -and $cells -contains 'Publisher') { $headers = $cells }
            continue
        }
        if ($cells.Count -ne $headers.Count) { throw 'Unrecognized Store table columns.' }
        $row = @{}
        for ($i = 0; $i -lt $headers.Count; $i++) { $row[$headers[$i]] = $cells[$i] }
        if ($row['Name']) { $rows += [pscustomobject]$row }
    }
    if ($null -eq $headers) { throw 'Unrecognized Store CLI table output.' }
    return $rows
}

function ConvertFrom-UsageStoreUpdates {
    param([string]$Text)
    if ($Text -match '(?im)^\s*(?:Error:|Failed\b|Cannot\b)') { throw 'Store update query failed.' }
    if ($Text -match '(?m)^\s*No updates found\.\s*$') { return $false }
    $rows = @(ConvertFrom-UsageStoreTable $Text)
    $matches = @($rows | Where-Object { $_.Name -ceq 'ChatGPT' -and $_.Publisher -ceq 'OpenAI' })
    if ($matches.Count -gt 1) { throw 'Ambiguous ChatGPT entries in Store update list.' }
    return $matches.Count -eq 1
}

function Get-UsageStoreStatus {
    param($Target, [string]$RunningPackageFullName, [switch]$LocalOnly)
    # The registered package is authoritative for the local copy. Store catalog
    # metadata can lag behind an already completed deployment or be unavailable.
    if ($Target.packageFullName -cnotmatch '^OpenAI\.Codex_([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)_x64__2p2nqsd0c76g0$') { throw 'Unrecognized installed package identity.' }
    $version = $Matches[1]
    $copyOld = -not [string]::IsNullOrWhiteSpace($RunningPackageFullName) -and $RunningPackageFullName -cne $Target.packageFullName
    $available = $false; $storeStatus = 'unchecked'; $storeError = $null; $storeCheckedAt = $null
    if (-not $LocalOnly) {
        $storeCheckedAt = [DateTime]::UtcNow.ToString('o')
        try {
            $installed = @(ConvertFrom-UsageStoreTable (Invoke-UsageStoreCommand installed))
            $entries = @($installed | Where-Object { $_.Name -ceq 'ChatGPT' -and $_.Publisher -ceq 'OpenAI' })
            if ($entries.Count -ne 1 -or -not $entries[0].PSObject.Properties['Version']) { throw 'Unrecognized Store metadata.' }
            if ($entries[0].Version -cne $version) { $storeError = 'metadata-pending'; throw 'Store metadata is refreshing.' }
            $available = ConvertFrom-UsageStoreUpdates (Invoke-UsageStoreCommand updates)
            $storeStatus = if ($available) { 'available' } else { 'current' }
        } catch {
            $storeStatus = 'error'
            if (-not $storeError) { $storeError = 'query-failed' }
        }
    }
    return [pscustomobject]@{
        schemaVersion = 1; status = $(if ($available -or $copyOld) { 'available' } elseif ($storeStatus -eq 'current') { 'current' } elseif ($storeStatus -eq 'error') { 'error' } else { 'unknown' })
        checkedAt = [DateTime]::UtcNow.ToString('o'); installedPackage = $Target.packageFullName
        installedVersion = $version; storeUpdateAvailable = [bool]$available; copyUpdateRequired = [bool]$copyOld
        storeStatus = $storeStatus; storeCheckedAt = $storeCheckedAt; storeError = $storeError
    }
}

function Invoke-UsageUpdateFlow {
    param(
        [scriptblock]$GetTarget, [scriptblock]$Check, [scriptblock]$Apply,
        [scriptblock]$Guard, [scriptblock]$Launch,
        [scriptblock]$Delay = { Start-Sleep -Seconds 5 },
        [scriptblock]$Log = { param($message) Write-Host $message },
        [int]$CompletionAttempts = 120
    )
    & $Guard
    $before = & $GetTarget
    & $Log "Installed package: $($before.packageFullName)"
    $state = & $Check $before
    if ($state.status -notin @('current','available')) { throw 'Microsoft Store could not be checked and no newer local original was confirmed. Retry Update.cmd later.' }
    if ($state.storeUpdateAvailable) {
        & $Guard
        & $Log 'Updating the original ChatGPT package through Microsoft Store.'
        & $Apply
        # Store may return after queuing deployment. A newer registered package
        # is required; unavailable/lagging catalog metadata cannot negate it.
        $completed = $false
        $oldVersion = [version](($before.packageFullName -split '_')[1])
        for ($i = 0; $i -lt $CompletionAttempts; $i++) {
            & $Guard
            try {
                $after = & $GetTarget
                $newVersion = [version](($after.packageFullName -split '_')[1])
                if ($newVersion -gt $oldVersion) {
                    $verified = & $Check $after
                    $catalogUnavailable = $verified.PSObject.Properties['storeStatus'] -and $verified.storeStatus -eq 'error'
                    if (-not $verified.storeUpdateAvailable -and ($verified.status -in @('current','available') -or $catalogUnavailable)) { $completed = $true; break }
                }
            } catch { if ($i -eq $CompletionAttempts - 1) { throw } }
            if ($i -lt $CompletionAttempts - 1) { & $Delay }
        }
        if (-not $completed) { throw 'Store update completion could not be verified. No copy was launched. Check Store and retry Update.cmd.' }
        & $Log "Verified updated package: $($after.packageFullName)"
    } elseif ($state.PSObject.Properties['storeStatus'] -and $state.storeStatus -eq 'error') {
        & $Log 'Store could not be checked. Preparing the copy from the already updated local original.'
    } else { & $Log 'No Store update is available. Preparing or reusing the current copy.' }
    & $Guard
    & $Launch
}

Export-ModuleMember -Function *-UsageStore*, Invoke-UsageUpdateFlow
