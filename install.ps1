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

# ---- 3. PATH entry for hand-installed CLI tools -----------------------------
Write-Host "`nUser PATH"
$bin      = Join-Path $env:LOCALAPPDATA 'Programs\bin'
$binEntry = '%LOCALAPPDATA%\Programs\bin'
# NB: read and write the RAW registry value. [Environment]::GetEnvironmentVariable
# expands %VARS% and SetEnvironmentVariable writes REG_SZ, so one round trip
# through them silently hard-codes every %USERPROFILE%-style entry already there.
$envKey  = 'HKCU:\Environment'
$rawPath = (Get-Item $envKey).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$parts   = @($rawPath -split ';' | Where-Object { $_ })
$present = $parts | Where-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $bin }
if ($present) {
    Write-Line '=' $binEntry
} elseif ($PSCmdlet.ShouldProcess('HKCU\Environment\Path', "Append $binEntry")) {
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    Set-ItemProperty -Path $envKey -Name Path -Value (($parts + $binEntry) -join ';') -Type ExpandString
    Write-Line '+' "$binEntry  (put the bat, eza, fd, rg and fzf .exe files here)"
    $pathChanged = $true
    $changed++
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

Write-Host "`nDone: $changed change(s)."
Write-Host 'Open a new Windows Terminal tab to pick up the profile and the environment.'
Write-Host 'Then check everything with: pwsh -File .\scripts\doctor.ps1'
