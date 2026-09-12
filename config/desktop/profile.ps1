# Desktop profile: MSI B450M Mortar MAX, Ryzen 5 3600, Radeon RX 570 8 GB,
# 16 GB DDR4-2400, 512 GB NVMe (a MAXIO drive whose firmware claims to be a
# Samsung), 1 TB HDD as G:. Everything the laptop
# has, plus games and creative apps. Get-DotfilesConfig (lib\profile.ps1) adds
# this to config\shared\targets.ps1. Data only: no param block, nothing that runs.

@{
    # Extra config files, same shape as Files in config\shared\targets.ps1.
    Files = @(
        # gameprep. The shared PowerShell profile loads profile.d\machine.ps1
        # when it exists, so the laptop never sees it.
        @{ Source = 'config\desktop\powershell\machine.ps1'; Target = Join-Path (Split-Path $PROFILE.CurrentUserCurrentHost) 'profile.d\machine.ps1' }
    )

    # Extra Win11Debloat switches. The shared list already fits a desktop.
    DebloatSwitches = @()

    # Extra rows for the memory table in scripts\doctor.ps1 (process name regex,
    # matched without .exe). None of them overlap a shared row.
    MemoryGroups = [ordered]@{
        'Steam'                  = '^(steam|steamwebhelper)$'
        'Epic Games Launcher'    = '^(EpicGamesLauncher|EpicWebHelper)$'
        'Minecraft (SKLauncher)' = '^(javaw|SKlauncher)'
        'Affinity'               = '^Affinity'
        'OBS'                    = '^obs64$'
        'Recordly'               = '^Recordly'
        'AMD Adrenalin'          = '^(RadeonSoftware|AMDRSServ|AMDRSSrcExt|atieclxx|amdfendrsr|cncmd)$'
    }
}
