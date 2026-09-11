# Desktop-only part of tune.ps1. Dot-sourced by it, so it runs in tune.ps1's
# scope and uses its helpers and -WhatIf: no param block, no exit.

# ---- Hibernation ------------------------------------------------------------
# No battery to save, and Fast Startup - the other user of hiberfil.sys - is
# already off (debloat\windows.ps1). hiberfil.sys is sized at 40% of RAM, so this
# gives back about 6.4 GB of the NVMe.
Write-Step 'Hibernation'
$hibernate = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue
if ($hibernate -eq 0) {
    Write-Line '=' 'hibernation is off'
} elseif ($PSCmdlet.ShouldProcess('Hibernation', 'Turn off and delete hiberfil.sys')) {
    powercfg /hibernate off
    Write-Line '+' 'hibernation off, hiberfil.sys deleted'
}

# ---- Reported, never changed ------------------------------------------------
# Security and power choices stay with you; docs\DESKTOP.md has the steps.
Write-Step 'Memory Integrity, Game Mode and power plan (reported only)'
$deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
if (-not $deviceGuard) {
    Write-Line '?' 'Memory Integrity state unavailable'
} elseif ($deviceGuard.SecurityServicesRunning -contains 2) {
    Write-Line '!' 'Memory Integrity is on. This machine runs with it off, set by hand: Windows Security > Device security > Core isolation details, then restart'
} else {
    Write-Line '=' 'Memory Integrity is off'
}

# Missing value = the Windows default, which is on.
$gameMode = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue
if ($gameMode -eq 0) { Write-Line '!' 'Game Mode is off: Settings > Gaming > Game Mode' }
else                 { Write-Line '=' 'Game Mode is on' }

Write-Line '=' ((powercfg /getactivescheme) -join ' ').Trim()
