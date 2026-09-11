#Requires -Version 7.0
<#
.SYNOPSIS
    Download the pinned SlimBrave Neo release, verify it, and open it.

.DESCRIPTION
    SlimBrave Neo writes Brave's enterprise policies (HKLM). Its Windows script is
    GUI-only - it has no flags - so a preset cannot be applied unattended. This
    fetches the exact release this repo was checked against, refuses to run it if
    the checksum does not match the one published with that release, puts the
    "Performance Focused" preset next to it, and launches it.

    Then, in the SlimBrave window:  Import -> "Performance Focused Preset.json" ->
    Apply Settings. Restart Brave and check brave://policy.

    The preset turns off background mode (Brave exits with its last window - on
    Windows it otherwise keeps running), turns on Memory Saver and hardware
    acceleration, and disables Rewards, Wallet, VPN, Leo, News, Talk and telemetry.
    Re-enable anything you use in the GUI before applying.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$tag    = 'v2.3.0'
# From the SHA256SUMS published with the v2.3.0 release.
$sha256 = 'de3e6e483ff9adf356668a8db488cc7d0d52cfd2cced7f90b8adcb20f386be51'
$base   = "https://raw.githubusercontent.com/ChaoticSi1ence/SlimBrave-Neo/$tag"

$dir    = Join-Path $env:TEMP "SlimBrave-Neo-$tag"
$script = Join-Path $dir 'SlimBrave.ps1'
$preset = Join-Path $dir 'Performance Focused Preset.json'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host "Downloading SlimBrave Neo $tag"
Invoke-WebRequest -Uri "$base/SlimBrave.ps1" -OutFile $script
$actual = (Get-FileHash -Path $script -Algorithm SHA256).Hash
if ($actual -ne $sha256) {
    Remove-Item $script
    throw "SlimBrave.ps1 checksum mismatch (got $actual). Not running it. Download it by hand from https://github.com/ChaoticSi1ence/SlimBrave-Neo/releases/tag/$tag and compare with SHA256SUMS."
}
Invoke-WebRequest -Uri "$base/Presets/Performance%20Focused%20Preset.json" -OutFile $preset
Unblock-File -Path $script, $preset

Write-Host @"

Checksum OK. Opening SlimBrave Neo (it asks for admin).
  1. Import -> $preset
  2. Review the toggles (Leo and Rewards are off in this preset)
  3. Apply Settings, then restart Brave and open brave://policy
"@
# Windows PowerShell, as SlimBrave Neo's own instructions use.
Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"")
