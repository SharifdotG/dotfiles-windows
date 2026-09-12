# Which machine is this, and what does its profile add to the shared config?
# Dot-sourced by install.ps1, tune.ps1, debloat\windows.ps1 and scripts\doctor.ps1.
#
# NB: never name a parameter or variable $Profile in a script that uses this
# file. Variable names are case-insensitive, so it would shadow the built-in
# $PROFILE that config\shared\targets.ps1 reads - and a child scope such as
# `& targets.ps1` sees the shadow too. The entry scripts use $MachineProfile,
# with -Profile only as a parameter alias.

function Get-DotfilesProfile {
    param([string]$Override)

    # 1. An explicit choice wins: -Profile on the command line, then the
    #    DOTFILES_PROFILE environment variable.
    foreach ($choice in $Override, $env:DOTFILES_PROFILE) {
        if (-not $choice) { continue }
        if ($choice -notin 'laptop', 'desktop') {
            throw "Unknown profile '$choice' - use laptop or desktop."
        }
        return $choice.ToLowerInvariant()
    }

    # 2. The SMBIOS chassis type. It is checked before the battery so a desktop on
    #    a UPS, which Windows lists as a battery, is still a desktop. Never the
    #    hostname: this repo is public.
    $laptop  = 8, 9, 10, 11, 14, 30, 31, 32       # portable, laptop, notebook, sub notebook, tablet, convertible, detachable
    $desktop = 3, 4, 5, 6, 7, 13, 15, 16, 35, 36  # desktop, low profile, tower, all in one, space-saving, mini PC
    $types = @((Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes)
    if ($types | Where-Object { $_ -in $laptop })  { return 'laptop' }
    if ($types | Where-Object { $_ -in $desktop }) { return 'desktop' }

    # 3. Retail motherboards often report "Other" or "Unknown". Fall back to
    #    whether there is a battery at all.
    if (Get-CimInstance -ClassName Win32_Battery) { 'laptop' } else { 'desktop' }
}

function Get-DotfilesConfig {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][ValidateSet('laptop', 'desktop')][string]$Machine
    )

    $shared = & (Join-Path $Repo 'config\shared\targets.ps1')
    $extra  = & (Join-Path $Repo "config\$Machine\profile.ps1")

    # @($x | Where-Object { $_ }) rather than @($x): @($null) is a one-element
    # array, which would add an empty file entry.
    @{
        Name            = $Machine
        Files           = @(@($shared.Files) + @($extra.Files | Where-Object { $_ }))
        Env             = $shared.Env
        DevDriveCaches  = $shared.DevDriveCaches
        DebloatSwitches = @($extra.DebloatSwitches | Where-Object { $_ })
        Wallpaper       = $shared.Wallpaper
        MemoryGroups    = if ($extra.MemoryGroups) { $extra.MemoryGroups } else { [ordered]@{} }
    }
}
