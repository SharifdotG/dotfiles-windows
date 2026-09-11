#Requires -Version 7.0
<#
.SYNOPSIS
    Debloat Windows 11 with the pinned Win11Debloat release - silently, and without
    removing Teams.

.DESCRIPTION
    Win11Debloat (github.com/Raphire/Win11Debloat, MIT) does all the work. This file
    only decides what to ask it for, so every choice is visible in one place.

    Needs admin and relaunches itself elevated. Safe to re-run: Windows feature
    updates reinstall some of these apps, and scripts\doctor.ps1 reports which.

    NB: Win11Debloat's own default app list removes the NEW Teams (MSTeams). This
    file starts from that list and keeps Teams. Running Win11Debloat by hand with
    -RunDefaults would remove it.

.PARAMETER MachineProfile
    -Profile laptop or -Profile desktop. Normally omitted: lib\profile.ps1 reads
    the chassis type. The DOTFILES_PROFILE environment variable also overrides it.

.EXAMPLE
    pwsh -File .\debloat\windows.ps1
#>
[CmdletBinding()]
param(
    # Not $Profile: it would shadow the built-in $PROFILE (lib\profile.ps1).
    [ValidateSet('laptop', 'desktop')]
    [Alias('Profile')]
    [string]$MachineProfile
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\profile.ps1')
$machine = Get-DotfilesConfig -Repo $repo -Machine (Get-DotfilesProfile -Override $MachineProfile)

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # -NoExit keeps the elevated window open so its output can be read. The
    # profile is passed on: the elevated process gets a fresh environment.
    Start-Process pwsh -Verb RunAs -ArgumentList @('-NoProfile', '-NoExit', '-File', "`"$PSCommandPath`"", '-Profile', $machine.Name)
    return
}
Write-Host "Profile: $($machine.Name)"

# ---- Pinned release ---------------------------------------------------------
# Bump deliberately: check every switch in $settings against the new release's
# Win11Debloat.ps1 param() block, and $keep/$extra against its Config\Apps.json.
$tag = '2026.08.24'

# ---- Apps -------------------------------------------------------------------
# Start from Win11Debloat's own default selection (SelectedByDefault in
# Config\Apps.json - Clipchamp, the Bing apps, Copilot, Solitaire, To Do, OEM
# trialware and so on), then adjust it:
$keep = @(
    'MSTeams'                                # Teams (new) - used natively for work
)
$extra = @(
    'Microsoft.BingSearch'                   # Bing search app
    'Microsoft.GetHelp'
    'Microsoft.OneDrive'                     # Microsoft 365 setup adds it; config\shared\office\configuration.xml excludes it too
    'Microsoft.YourPhone'                    # Phone Link
    'MicrosoftWindows.CrossDevice'           # Phone Link's background half
    'Microsoft.StartExperiencesApp'          # Widgets board
    'MicrosoftWindows.Client.WebExperience'  # Widgets' WebView2 host
    'Microsoft.People'
    'Microsoft.windowscommunicationsapps'    # old Mail and Calendar
    'Microsoft.M365Companions'
    'Microsoft.OutlookForWindows'            # new Outlook - no Outlook of either kind is used
)
# Deliberately NOT removed: Edge (Windows components still lean on it),
# Photos, Paint, Snipping Tool, Notepad, Calculator, Camera, Store, Terminal,
# Media Player - none of them run in the background.

# ---- Settings ---------------------------------------------------------------
$settings = @(
    '-Silent'
    '-CreateRestorePoint'

    # Telemetry, ads and background activity
    '-DisableTelemetry'
    '-DisableSuggestions'               # tips and ads in Start, Settings, Explorer, notifications
    '-DisableLockscreenTips'
    '-DisableSettings365Ads'
    '-DisableStoreSearchSuggestions'
    '-DisableBing'                      # Bing web search, Bing AI and Cortana in Windows Search
    '-DisableSearchHighlights'
    '-DisableDesktopSpotlight'          # no background wallpaper and "learn more" downloads
    '-DisableDeliveryOptimization'      # no uploading updates to other PCs
    '-DisableDeviceAutoAppDownload'     # no companion apps pulled in by plugged-in devices

    # AI features - each is a background service or a WebView2 host
    '-DisableCopilot'
    '-DisableRecall'
    '-DisableClickToDo'
    '-DisableAISvcAutoStart'
    '-DisableEdgeAI'
    '-DisablePaintAI'
    '-DisableNotepadAI'

    # Always-on WebView2 surfaces
    '-DisableWidgets'
    '-DisableEdgeAds'
    '-HideChat'

    # Xbox app, Game Bar and background recording. Nothing uses them: the
    # desktop's games come from Steam and Epic, OBS and Recordly do the
    # recording, and Game Mode is a separate setting that stays on.
    '-RemoveGamingApps'
    '-DisableDVR'
    '-DisableGameBarIntegration'

    # Start and Explorer
    '-DisableStartRecommended'
    '-DisableStartPhoneLink'
    '-ShowKnownFileExt'
    '-Hide3dObjects'
    '-DisableDragTray'

    # Escape hatch: "End task" on the taskbar right-click menu - the nearest thing
    # Windows has to the Linux setup's Alt+SysRq+F.
    '-EnableEndTask'

    # Power
    '-DisableFastStartup'               # Shut down becomes a real shutdown, not a hibernated kernel
)
# Per machine, from config\<profile>\profile.ps1 - the laptop adds
# -DisableModernStandbyNetworking.
$settings += $machine.DebloatSwitches
# Deliberately NOT used:
#   -DisableAnimations, -DisableTransparency  single-digit MB (the Plasma lesson)
#   -DisableBraveBloat                        SlimBrave Neo owns Brave's policies here
#   -DisableStorageSense                      it is the cleanup this machine relies on
#   -DisableNotifications                     Teams and WhatsApp need them

# ---- Fetch the pinned release -----------------------------------------------
$work = Join-Path $env:TEMP "Win11Debloat-$tag"
if (-not (Test-Path (Join-Path $work 'Win11Debloat.ps1'))) {
    $zip     = "$work.zip"
    $extract = "$work.extract"
    Write-Host "Downloading Win11Debloat $tag"
    Invoke-WebRequest -Uri "https://github.com/Raphire/Win11Debloat/archive/refs/tags/$tag.zip" -OutFile $zip
    Remove-Item $work, $extract -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $extract
    # The archive holds a single top-level folder; flatten it.
    Move-Item -Path (Get-ChildItem $extract -Directory | Select-Object -First 1).FullName -Destination $work
    Remove-Item $zip, $extract -Recurse -Force
}
# Downloaded files carry Mark-of-the-Web; Win11Debloat dot-sources dozens of them.
Get-ChildItem $work -Recurse -File | Unblock-File

# ---- Build the app list -----------------------------------------------------
$appsJson  = Get-Content (Join-Path $work 'Config\Apps.json') -Raw | ConvertFrom-Json
# AppId is a string for most entries and an array for a few (Edge); a foreach
# statement's output flattens both into one list.
$supported = foreach ($app in $appsJson.Apps) { $app.AppId }
$default   = foreach ($app in $appsJson.Apps) { if ($app.SelectedByDefault) { $app.AppId } }

# Win11Debloat SKIPS an id it does not know, and only says so in its own output.
# Fail here instead, so a renamed id in a future release cannot quietly leave an
# app installed.
$unknown = @($keep + $extra) | Where-Object { $_ -notin $supported }
if ($unknown) {
    throw "Not in Win11Debloat $tag Config\Apps.json: $($unknown -join ', '). Update `$keep/`$extra."
}
$selection = @(@($default | Where-Object { $_ -notin $keep }) + $extra | Select-Object -Unique)

# ---- Run --------------------------------------------------------------------
# -CreateRestorePoint needs System Protection on for C:, which a fresh install
# often has off. Enable-ComputerRestore only exists in Windows PowerShell.
powershell.exe -NoProfile -Command "Enable-ComputerRestore -Drive 'C:\'"

Write-Host "Removing $($selection.Count) apps (Teams kept) and applying $($settings.Count - 2) settings"
# Win11Debloat is written for Windows PowerShell (its Appx and GUI code), so run
# it there rather than in PowerShell 7.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'Win11Debloat.ps1') @settings -RemoveApps -Apps ($selection -join ',')
if ($LASTEXITCODE) {
    Write-Warning "Win11Debloat exited with code $LASTEXITCODE - read its output above."
}

Write-Host "`nRestart Windows, then check with: pwsh -File .\scripts\doctor.ps1"
