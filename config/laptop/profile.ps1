# Laptop profile: ThinkPad T490s - i5-8365U, Intel UHD 620, 16 GB soldered,
# 238 GB NVMe. Get-DotfilesConfig (lib\profile.ps1) adds this to
# config\shared\targets.ps1. Data only: no param block, nothing that runs.

@{
    # Extra config files, same shape as Files in config\shared\targets.ps1.
    Files           = @()

    # Extra Win11Debloat switches, appended to the list in debloat\windows.ps1.
    DebloatSwitches = @(
        # Most of Modern Standby's overnight drain, if S3 turns out to be
        # unavailable (docs\LAPTOP.md, Sleep).
        '-DisableModernStandbyNetworking'
    )

    # Extra rows for the memory table in scripts\doctor.ps1. The shared ones cover
    # this machine.
    MemoryGroups    = [ordered]@{}
}
