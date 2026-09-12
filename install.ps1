#Requires -Version 7.0
<#
.SYNOPSIS
    Put this repo's config files in place and set the user environment variables.

.DESCRIPTION
    User-level; never needs admin. Re-running it is the normal update path after
    editing anything under config\. A target that differs from the repo copy is
    saved as <file>.bak-<timestamp> before it is replaced, so nothing is lost.

.PARAMETER DevDrive
    Letter of a Dev Drive, e.g. D:. The npm, NuGet and pip caches are pointed at
    <letter>:\packages so package restores run on ReFS, with Defender in
    performance mode, instead of paying real-time scanning on C:.

.PARAMETER MachineProfile
    -Profile laptop or -Profile desktop. Normally omitted: lib\profile.ps1 reads
    the chassis type. The DOTFILES_PROFILE environment variable also overrides it.

.EXAMPLE
    pwsh -File .\install.ps1 -WhatIf

.EXAMPLE
    pwsh -File .\install.ps1 -DevDrive D:
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$DevDrive,

    # Not $Profile: it would shadow $PROFILE, which config\shared\targets.ps1 reads.
    [ValidateSet('laptop', 'desktop')]
    [Alias('Profile')]
    [string]$MachineProfile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\profile.ps1')
$machine     = Get-DotfilesConfig -Repo $PSScriptRoot -Machine (Get-DotfilesProfile -Override $MachineProfile)
$changed     = 0
$pathChanged = $false

function Write-Line([string]$Mark, [string]$Text) { Write-Host "  $Mark $Text" }

Write-Host "Profile: $($machine.Name)`n"

# ---- 1. Config files --------------------------------------------------------
Write-Host 'Config files'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($file in $machine.Files) {
    $src = Join-Path $PSScriptRoot $file.Source
    $dst = $file.Target

    if ($file.OnlyIf -and -not (Test-Path $file.OnlyIf)) {
        Write-Line '-' "$dst  (app not installed - skipped)"
        continue
    }
    if ((Test-Path $dst) -and (Get-FileHash $dst).Hash -eq (Get-FileHash $src).Hash) {
        Write-Line '=' $dst
        continue
    }
    if ($PSCmdlet.ShouldProcess($dst, "Copy $($file.Source)")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
        if (Test-Path $dst) { Copy-Item $dst "$dst.bak-$stamp" }
        Copy-Item $src $dst -Force
        Write-Line '+' $dst
        $changed++
    }
}

# ---- 2. Git identity --------------------------------------------------------
# Your name and email live in ~/.gitconfig, which this script creates once and
# never replaces; the managed settings are in ~/.config/git/config (step 1). Git
# reads both, and once ~/.gitconfig exists `git config --global` and GitHub
# Desktop write there as well - which is what keeps their changes out of the file
# this script overwrites.
Write-Host "`nGit identity"
$gitUser = Join-Path $HOME '.gitconfig'
$hasGit  = Get-Command git -CommandType Application -ErrorAction Ignore
$name    = if ($hasGit -and (Test-Path $gitUser)) { git config --file $gitUser user.name }
if ($name) {
    Write-Line '=' "$gitUser ($name)"
} elseif ($PSCmdlet.ShouldProcess($gitUser, 'Set your name and email')) {
    $name  = Read-Host '    Full name for git commits'
    $email = Read-Host '    Email for git commits'
    if ($hasGit) {
        git config --file $gitUser user.name $name
        git config --file $gitUser user.email $email
    } else {
        Add-Content -Path $gitUser -Value "[user]`n`tname = $name`n`temail = $email"
    }
    Write-Line '+' $gitUser
    $changed++
}

# ---- 3. PATH entries installers do not add themselves -----------------------
Write-Host "`nUser PATH"
# Entry = the raw %VAR% form to store; Note = why; Create = make the folder if it
# is missing (only for the one this repo owns).
#
# winget-installed tools (bat, eza, fd, rg, fzf, starship) need nothing here:
# winget shims them into %LOCALAPPDATA%\Microsoft\WinGet\Links and puts that on
# PATH itself. Claude Code's installer is the one that does not - it drops
# claude.exe in ~\.local\bin and leaves PATH alone, so `claude` is missing from
# every new shell until this runs.
$pathEntries = @(
    @{ Entry = '%LOCALAPPDATA%\Programs\bin'; Note = 'a spare folder for one-off .exe files'; Create = $true }
    @{ Entry = '%USERPROFILE%\.local\bin';    Note = 'where claude.ai/install.ps1 puts claude.exe' }
)
# NB: read and write the RAW registry value. [Environment]::GetEnvironmentVariable
# expands %VARS% and SetEnvironmentVariable writes REG_SZ, so one round trip
# through them silently hard-codes every %USERPROFILE%-style entry already there.
$envKey  = 'HKCU:\Environment'
foreach ($entry in $pathEntries) {
    $expanded = [Environment]::ExpandEnvironmentVariables($entry.Entry).TrimEnd('\')
    $rawPath  = (Get-Item $envKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $parts    = @($rawPath -split ';' | Where-Object { $_ })
    $present  = $parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $expanded }
    if ($present) {
        Write-Line '=' $entry.Entry
    } elseif ($PSCmdlet.ShouldProcess('HKCU\Environment\Path', "Append $($entry.Entry)")) {
        if ($entry.Create) { New-Item -ItemType Directory -Force -Path $expanded | Out-Null }
        Set-ItemProperty -Path $envKey -Name Path -Value (($parts + $entry.Entry) -join ';') -Type ExpandString
        Write-Line '+' "$($entry.Entry)  ($($entry.Note))"
        $pathChanged = $true
        $changed++
    }
}

# ---- 4. User environment variables ------------------------------------------
Write-Host "`nUser environment variables"
$vars = [ordered]@{}
foreach ($kv in $machine.Env.GetEnumerator()) { $vars[$kv.Key] = $kv.Value }

if ($DevDrive) {
    $letter = $DevDrive.Substring(0, 1).ToUpper()
    $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    if (-not $volume) {
        throw "${letter}: does not exist. Create the Dev Drive first (docs\$($machine.Name.ToUpper()).md, Dev Drive)."
    }
    if ($volume.FileSystemType -ne 'ReFS') {
        throw "${letter}: is $($volume.FileSystemType), not a Dev Drive (ReFS). Moving caches there would buy nothing."
    }
    foreach ($kv in $machine.DevDriveCaches.GetEnumerator()) {
        $dir = "${letter}:\packages\$($kv.Value)"
        if (-not (Test-Path $dir) -and $PSCmdlet.ShouldProcess($dir, 'Create cache folder')) {
            New-Item -ItemType Directory -Path $dir | Out-Null
        }
        $vars[$kv.Key] = $dir
    }
}

$broadcast = $false
foreach ($kv in $vars.GetEnumerator()) {
    if ([Environment]::GetEnvironmentVariable($kv.Key, 'User') -eq $kv.Value) {
        Write-Line '=' "$($kv.Key)=$($kv.Value)"
        continue
    }
    if ($PSCmdlet.ShouldProcess("User environment variable $($kv.Key)", "Set to $($kv.Value)")) {
        # SetEnvironmentVariable also broadcasts WM_SETTINGCHANGE, so apps started
        # from now on see the value without signing out.
        [Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'User')
        Write-Line '+' "$($kv.Key)=$($kv.Value)"
        $broadcast = $true
        $changed++
    }
}
# The PATH write above goes straight to the registry and announces nothing. If no
# variable changed in this run either, re-set one to its current value purely to
# send that broadcast.
if ($pathChanged -and -not $broadcast -and -not $WhatIfPreference) {
    $first = @($vars.Keys)[0]
    [Environment]::SetEnvironmentVariable($first, $vars[$first], 'User')
}

# ---- 5. Desktop wallpaper ---------------------------------------------------
# The file itself was copied by step 1, like any other config file. This only
# points Windows at it. Two halves, and both are needed: the registry values are
# what survives a sign-out, and SystemParametersInfo is what applies them now
# instead of at the next sign-in.
Write-Host "`nDesktop wallpaper"
$paper = $machine.Wallpaper
if (-not (Test-Path $paper.Path)) {
    Write-Line '-' "$($paper.Path) is missing - nothing to set"
} else {
    $desktop = 'HKCU:\Control Panel\Desktop'
    $current = Get-ItemProperty -Path $desktop -ErrorAction SilentlyContinue
    if ($current.WallPaper -eq $paper.Path -and $current.WallpaperStyle -eq $paper.Style -and $current.TileWallpaper -eq $paper.Tile) {
        Write-Line '=' $paper.Path
    } elseif ($PSCmdlet.ShouldProcess($paper.Path, 'Set as the desktop wallpaper')) {
        Set-ItemProperty -Path $desktop -Name WallPaper       -Value $paper.Path
        Set-ItemProperty -Path $desktop -Name WallpaperStyle  -Value $paper.Style
        Set-ItemProperty -Path $desktop -Name TileWallpaper   -Value $paper.Tile
        # SPI_SETDESKWALLPAPER = 0x0014. SPIF_UPDATEINIFILE (1) | SPIF_SENDCHANGE (2)
        # makes Explorer re-read it and redraw straight away. Windows then keeps its
        # own re-encoded copy in %APPDATA%\Microsoft\Windows\Themes, so the file
        # above is read at sign-in rather than held open.
        if (-not ('DotfilesWallpaper' -as [type])) {
            Add-Type -Name DotfilesWallpaper -Namespace Dotfiles -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
'@
        }
        $applied = [Dotfiles.DotfilesWallpaper]::SystemParametersInfo(0x0014, 0, $paper.Path, 0x0001 -bor 0x0002)
        Write-Line '+' "$($paper.Path)$(if (-not $applied) { ' (set for next sign-in; Explorer did not redraw)' })"
        $changed++
    }
}

Write-Host "`nDone: $changed change(s)."
Write-Host 'Open a new Windows Terminal tab to pick up the profile and the environment.'
Write-Host 'Then check everything with: pwsh -File .\scripts\doctor.ps1'
