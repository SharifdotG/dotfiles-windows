# Desktop-only checks for scripts\doctor.ps1. Dot-sourced by it, so it runs in
# doctor.ps1's scope and uses its helpers and variables ($isAdmin, $procs,
# $startup): no param block, no exit. Read-only.
#
# NB: doctor.ps1 goes on using $groups, $rows, $total and $accounted after this
# file - don't reuse those names here.

# ---- Hardware ---------------------------------------------------------------
Section 'Hardware'
# The shared Graphics section already fails on Microsoft Basic Display Adapter.
$radeon = Get-CimInstance -ClassName Win32_VideoController |
    Where-Object { $_.PNPDeviceID -like 'PCI\VEN_1002*' -and $_.Name -notmatch 'Basic Display' } |
    Select-Object -First 1
if ($radeon) { Ok "$($radeon.Name), driver $($radeon.DriverVersion)" }
else         { Warn 'no AMD driver on the RX 570 - install Adrenalin (docs\DESKTOP.md, Drivers)' }

# ConfiguredClockSpeed is what the memory runs at; Speed is only its rating.
$dimms    = @(Get-CimInstance -ClassName Win32_PhysicalMemory)
$ramSpeed = ($dimms | Measure-Object -Property ConfiguredClockSpeed -Minimum).Minimum
$ramSize  = ($dimms | Measure-Object -Property Capacity -Sum).Sum
if ($ramSpeed -ge 2400) { Ok "RAM $(GB $ramSize) running at $ramSpeed MT/s" }
else                    { Warn "RAM runs at $ramSpeed MT/s, not 2400 - BIOS: OC > DRAM Setting > A-XMP > Profile 1 (docs\DESKTOP.md, BIOS)" }

if ((Get-CimInstance -ClassName Win32_Processor).VirtualizationFirmwareEnabled) {
    Ok 'SVM Mode on (virtualization enabled in firmware)'
} else {
    Fail 'SVM Mode is off - Docker Desktop cannot start its VM. BIOS: OC > CPU Features > SVM Mode'
}

# ---- The HDD ----------------------------------------------------------------
Section 'Storage (G:)'
$hdd = Get-Volume -DriveLetter G -ErrorAction SilentlyContinue
if (-not $hdd) {
    Warn 'no G: drive - give the HDD letter G: in Disk Management (docs\DESKTOP.md, Install)'
} else {
    if ($hdd.FileSystemType -eq 'NTFS') { Ok "G: ($($hdd.FileSystemLabel)) is NTFS, $(GB $hdd.SizeRemaining) free of $(GB $hdd.Size)" }
    else                                { Fail "G: is $($hdd.FileSystemType), expected the NTFS HDD" }
    $hddDisk = Get-Partition -DriveLetter G -ErrorAction SilentlyContinue | Get-Disk -ErrorAction SilentlyContinue
    if ($hddDisk.HealthStatus -eq 'Healthy') { Ok "$($hddDisk.FriendlyName) reports Healthy" }
    else                                     { Warn "$($hddDisk.FriendlyName) reports '$($hddDisk.HealthStatus)' - copy G:\Storage somewhere safe" }
    if (Test-Path 'G:\SteamLibrary') { Ok 'G:\SteamLibrary exists' }
    else                             { Warn 'G:\SteamLibrary missing - Steam > Settings > Storage > Add Drive > G: (docs\DESKTOP.md, Steam)' }
}

# ---- Power ------------------------------------------------------------------
Section 'Power'
$hibernation = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue
if ($hibernation -eq 0) { Ok 'hibernation off (no hiberfil.sys)' } else { Warn 'hibernation on - run tune.ps1' }

# Balanced keeps the Power mode slider. The AMD chipset driver's "AMD Ryzen
# Balanced" plan is fine too; High and Ultimate Performance hide the slider.
$plan     = powercfg /getactivescheme | Out-String
$planName = if ($plan -match '\(([^)]+)\)') { $Matches[1] } else { $plan.Trim() }
if ($plan -match '381b4222-f694-41f0-9685-ff5bb260df2e' -or $planName -match 'Balanced') {
    Ok "power plan: $planName"
} else {
    Warn "power plan: $planName - switch back with: powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e"
}
$acOverlay = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' `
    -Name ActiveOverlayAcPowerScheme -ErrorAction SilentlyContinue
if ($acOverlay -eq 'ded574b5-45a0-4f42-8737-46345c09c238') { Ok 'power mode: Best performance' }
else { Info 'power mode is not Best performance - Settings > System > Power > Power mode (docs\DESKTOP.md, Power)' }

# ---- Memory Integrity and WSL -----------------------------------------------
Section 'Memory Integrity and WSL'
if ($isAdmin) {
    $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    if (-not $deviceGuard)                                    { Warn 'Device Guard status unavailable' }
    elseif ($deviceGuard.SecurityServicesRunning -contains 2) { Warn 'Memory Integrity is on - this machine runs with it off, set by hand (docs\DESKTOP.md, Memory Integrity)' }
    else                                                      { Ok 'Memory Integrity off (chosen for this machine)' }
} else {
    Warn 'Memory Integrity not checked - Win32_DeviceGuard needs an elevated terminal'
}
# Memory Integrity is separate from the Virtual Machine Platform that WSL 2 and
# Docker Desktop run on; this proves that platform still works.
if (Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue) {
    $null = wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { Ok 'wsl --status responds' }
    else                     { Fail "wsl --status exited $LASTEXITCODE - check SVM Mode, then: wsl --install --no-distribution" }
} else {
    Warn 'wsl.exe not found - Docker Desktop installs WSL on its first start'
}

# ---- GPU tuning -------------------------------------------------------------
Section 'GPU tuning'
# One owner per hardware knob - the Linux ppfeaturemask lesson. Adrenalin sets
# the fan curve and power limit; a second tuner fights it for the same settings.
$tuners = @($procs | ForEach-Object { $_.Name -replace '#\d+$' } | Where-Object { $_ -match '^(MSIAfterburner|FanControl)$' }) +
          @($startup | Where-Object { $_ -match 'afterburner|fancontrol' })
if ($tuners) { Warn "second GPU tuner found: $(($tuners | Select-Object -Unique) -join ', ') - Adrenalin owns fans and power limit here" }
else         { Ok 'Adrenalin is the only GPU tuner' }
