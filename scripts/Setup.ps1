[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$DependenciesOnly,
    [switch]$EnableClaude,
    [switch]$DisableClaude,
    [switch]$DisableAntigravity,
    [string]$AntigravityPath
)
$ErrorActionPreference = 'Stop'
if ($EnableClaude -and $DisableClaude) { throw 'Choose EnableClaude or DisableClaude, not both.' }
Import-Module (Join-Path $PSScriptRoot 'UsageCopy.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Environment.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $ProjectRoot 'patcher/AppPatch.Common.psm1') -DisableNameChecking
if (-not $DependenciesOnly) { Assert-UsageCopySetupStopped $ProjectRoot }
$environment = & (Join-Path $PSScriptRoot 'Install-Dependencies.ps1') -ProjectRoot $ProjectRoot
if ($DependenciesOnly) { $environment; return }
$file = Join-Path $ProjectRoot '.local/settings.json'
if ([IO.File]::Exists($file)) {
    $settings = (Get-UsageSettings $ProjectRoot).value
    $settings.nodePath = $environment.nodePath
} else {
    $homePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $settings = [pscustomobject]@{
        schemaVersion=1; packageName='OpenAI.Codex'; packageFamilyName='OpenAI.Codex_2p2nqsd0c76g0'
        nodePath=$environment.nodePath; agyPath=$null; codexHome=$homePath
        userProfile=$env:USERPROFILE; appData=$env:APPDATA; localAppData=$env:LOCALAPPDATA
        userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; claudeEnabled=$true
        usage=[pscustomobject]@{language='auto'}
    }
    $candidate = Join-Path $env:LOCALAPPDATA 'agy/bin/agy.exe'
    if ([IO.File]::Exists($candidate)) { $settings.agyPath = $candidate }
}
if ($AntigravityPath) { $settings.agyPath = (Get-Item -LiteralPath $AntigravityPath -ErrorAction Stop).FullName }
if ($DisableAntigravity) { $settings.agyPath = $null }
if ($EnableClaude -or $DisableClaude) { $settings | Add-Member -Force -NotePropertyName claudeEnabled -NotePropertyValue ([bool]$EnableClaude) }
# Existing installations without claudeEnabled retain their previous explicit configuration.
$configuration = [pscustomobject]@{root=$ProjectRoot;value=$settings}
$target = Get-UsageTarget $configuration
try { $null = Get-UsageCopyProfiles $settings } catch { throw 'Open the original app and sign in once before setup. Its existing Codex profile is required.' }
Assert-UsageCopySetupStopped $ProjectRoot
Write-AppJson $file $settings
$prepared = & (Join-Path $PSScriptRoot 'Prepare-UsageCopy.ps1') -ProjectRoot $ProjectRoot -Confirm:$false
$hold = Join-Path $ProjectRoot '.local/copy/restore-hold.json'
if ([IO.File]::Exists($hold)) { Remove-Item -LiteralPath $hold }
& (Join-Path $PSScriptRoot 'Install-UsageShortcut.ps1') -ProjectRoot $ProjectRoot -UpdateExistingPin | Out-Host
Write-Host 'Setup complete. Open ChatGPT with usage from the Start menu. Right-click its shortcut and choose Pin to taskbar once; existing pins are updated automatically.'
$originalRunning = $false
try { $originalRunning = @(Get-UsageCopyOriginalProcesses -SourceAppDir $target.appDir).Count -gt 0 }
catch { Write-Verbose 'Could not check the original app after setup; direct launch checks again.' }
if ($originalRunning) {
    Write-Warning 'The original ChatGPT app is still running. Close it before opening ChatGPT with usage; the apps share your login, conversations and profile.'
}
$prepared
