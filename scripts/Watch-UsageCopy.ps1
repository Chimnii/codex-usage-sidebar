[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$LaunchPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
$launchPath = Assert-AppPlainPath $LaunchPath
if (-not (Test-AppPathInside $launchPath (Join-Path $projectRoot '.local/copy/launches'))) { throw 'Unexpected launch report path.' }
$launch = Read-AppJson $launchPath
$copyRoot = Join-Path $projectRoot '.local/copy'
$legacy = Join-Path $copyRoot 'builds'
$active = Join-Path $copyRoot 'active'
if (-not ((Test-AppPathInside $launch.layerRoot $legacy) -and (Test-AppPathInside $launch.appDir $legacy)) -and
    -not ($launch.layerRoot -ieq (Join-Path $active 'layer-data') -and $launch.appDir -ieq (Join-Path $active 'app'))) { throw 'Unexpected copy path.' }
$statusPath = Join-Path $launch.layerRoot 'tweak-data/local.sidebar-usage-demo/bridge-status.json'
$collectorConfig = Read-AppJson (Join-Path $launch.layerRoot 'tweak-data/local.sidebar-usage-demo/collector-config.json')
$claudeEnabled = $collectorConfig.PSObject.Properties['claudeCredentialsPath'] -and -not [string]::IsNullOrWhiteSpace([string]$collectorConfig.claudeCredentialsPath) -and [IO.File]::Exists($collectorConfig.claudeCredentialsPath)
$deadline = [DateTime]::UtcNow.AddSeconds(180)
$status = $null
$checks = $null
$result = 'timed-out'
try {
    do {
        Start-Sleep -Seconds 2
        $running = @(Get-CimInstance Win32_Process -Filter "Name = 'ChatGPT.exe'" | Where-Object ExecutablePath -IEQ (Join-Path $launch.appDir 'ChatGPT.exe'))
        $webProfiles = @(foreach ($process in $running) {
            foreach ($match in [regex]::Matches([string]$process.CommandLine, '(?:"--user-data-dir=([^"]+)"|--user-data-dir="([^"]+)"|--user-data-dir=([^\s"]+))')) {
                foreach ($group in @($match.Groups[1],$match.Groups[2],$match.Groups[3])) { if ($group.Success) { $group.Value } }
            }
        }) | Select-Object -Unique
        try { $observed = Read-AppJson $statusPath } catch { $observed = $null }
        if ($observed -and $observed.PSObject.Properties['launchId'] -and $observed.launchId -ceq $launch.launchId) {
            $status = $observed
            $gpt = @($status.providers | Where-Object id -CEQ 'codex')[0]
            $gemini = @($status.providers | Where-Object id -CEQ 'antigravity')[0]
            $claude = @($status.providers | Where-Object id -CEQ 'claude')[0]
            $uiOk = $null -ne $status.ui -and $null -ne $status.ui.PSObject.Properties['detectorVersion'] -and
                $status.ui.detectorVersion -eq 2 -and $status.ui.visiblePanels -gt 0 -and $status.ui.withinSidebar -and -not $status.ui.snagDetected
            $checks = [pscustomobject]@{
                # Owl-backed builds return the nested Chromium profile from
                # app.getPath('userData'); Electron builds can return its parent.
                # Both are original locations; the OS-level web profile is also
                # independently checked below against the exact original path.
                originalRuntimeProfile = @($launch.profiles.electronUserData, $launch.profiles.webProfile) -icontains $status.runtime.userData
                originalWebProfile = @($webProfiles) -icontains $launch.profiles.webProfile
                originalCodexHome = $status.runtime.codexHome -ieq $launch.profiles.codexHome
                selectedCopy = $status.runtime.executable -ieq (Join-Path $launch.appDir 'ChatGPT.exe')
                sidebarPanel = $uiOk
                gptUsage = $gpt.status -ceq 'ok'; antigravityUsage = $gemini.status -ceq 'ok'
                claudeUsage = if ($claudeEnabled) { $claude.status -ceq 'ok' -and $claude.checkedAt -and ([DateTime]$claude.checkedAt).ToUniversalTime() -gt ([DateTime]$launch.startedAt).ToUniversalTime() } else { $claude.status -ceq 'disconnected' }
                claudePanel = (-not $claudeEnabled) -or ($null -ne $status.ui -and $null -ne $status.ui.PSObject.Properties['claudeRows'] -and $status.ui.claudeRows -gt 0)
                repeatedRefresh = $status.cycles -ge 2 -and -not $status.active -and $gpt.checkedAt -and $gemini.checkedAt -and
                    ([DateTime]$gpt.checkedAt).ToUniversalTime() -gt ([DateTime]$launch.startedAt).ToUniversalTime() -and
                    ([DateTime]$gemini.checkedAt).ToUniversalTime() -gt ([DateTime]$launch.startedAt).ToUniversalTime()
            }
            if (@($checks.PSObject.Properties | Where-Object { $_.Value -ne $true }).Count -eq 0) { $result = 'panel-and-refresh-confirmed'; break }
        }
        if (-not $running.Count) { $result = 'app-exited'; break }
    } while ([DateTime]::UtcNow -lt $deadline)
    $launch.verification = $result
    $launch | Add-Member -NotePropertyName checkedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $launch | Add-Member -NotePropertyName checks -NotePropertyValue $checks -Force
    $launch | Add-Member -NotePropertyName runtimeEvidence -NotePropertyValue $status -Force
    $launch | Add-Member -NotePropertyName observedWebProfiles -NotePropertyValue @($webProfiles) -Force
    # These observations establish profile selection, panel rendering and refresh.
    # Opening/resuming an existing conversation remains a separate interactive check.
    $launch | Add-Member -NotePropertyName conversationResume -NotePropertyValue 'requires-interactive-check' -Force
    Write-AppJson $launchPath $launch
}
catch {
    $launch.verification = 'verification-error'
    $launch | Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force
    Write-AppJson $launchPath $launch
}
