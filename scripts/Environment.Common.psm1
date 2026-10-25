Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'patcher/AppPatch.Common.psm1') -DisableNameChecking

function Get-UsageSettings {
    param([string]$ProjectRoot, [string]$SettingsPath)
    $root = Get-AppDirectory $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $root '.local/settings.json' }
    if (-not [IO.File]::Exists($SettingsPath)) { throw 'Setup is required. Close the app and run Setup.cmd first.' }
    $path = Assert-AppPlainPath $SettingsPath
    $settings = Read-AppJson $path
    if ($settings.schemaVersion -ne 1) { throw 'Unsupported local settings version.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($settings.userSid -cne $sid) { throw 'Run this script as the Windows user that prepared the project. Administrator rights are not required.' }
    return [pscustomobject]@{ root = $root; path = $path; value = $settings }
}

function Get-UsageTarget {
    param([Parameter(Mandatory = $true)]$Configuration, [string]$FixtureAppDir, [switch]$AllowFixture)
    if (-not [string]::IsNullOrWhiteSpace($FixtureAppDir)) {
        if (-not $AllowFixture) { throw '-FixtureAppDir requires explicit -AllowFixture.' }
        $fixture = Get-AppDirectory $FixtureAppDir
        $fixtureBase = Join-Path $Configuration.root '.local/tests'
        if (-not (Test-AppPathInside $fixture $fixtureBase)) { throw 'Fixture app must be inside this project .local/tests directory.' }
        return [pscustomobject]@{ appDir = $fixture; packageFullName = 'synthetic-fixture'; fixture = $true }
    }
    if ($AllowFixture) { throw '-AllowFixture requires -FixtureAppDir for installation.' }
    if ($Configuration.value.packageName -cne 'OpenAI.Codex' -or $Configuration.value.packageFamilyName -cne 'OpenAI.Codex_2p2nqsd0c76g0') { throw 'Local settings must identify the expected OpenAI.Codex package.' }
    $packages = @(Get-AppxPackage -Name $Configuration.value.packageName -ErrorAction Stop | Where-Object { $_.PackageFamilyName -ceq $Configuration.value.packageFamilyName })
    if ($packages.Count -ne 1) { throw "Expected one installed OpenAI.Codex package for this user; found $($packages.Count)." }
    $package = $packages[0]
    $app = Get-AppDirectory ([IO.Path]::Combine([string]$package.InstallLocation, 'app'))
    foreach ($relative in @('resources/app.asar', 'ChatGPT.exe')) { [void](Get-AppPairPath $app $relative) }
    return [pscustomobject]@{ appDir = $app; packageFullName = [string]$package.PackageFullName; fixture = $false }
}


Export-ModuleMember -Function Get-UsageSettings, Get-UsageTarget
