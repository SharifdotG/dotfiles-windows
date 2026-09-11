# Laptop-only checks for scripts\doctor.ps1. Dot-sourced by it, so it runs in
# doctor.ps1's scope and uses its helpers: no param block, no exit. Read-only.

# ---- Sleep and power --------------------------------------------------------
Section 'Sleep and power'
$sleep = powercfg /a | Out-String
# English output: the available states are listed before the "not available" heading.
$available = ($sleep -split 'not available')[0]
if ($available -match 'Standby \(S3\)') {
    Ok 'S3 sleep available - keep BIOS Sleep State = Linux (about 2% overnight drain, measured on CachyOS)'
} elseif ($available -match 'S0 Low Power Idle') {
    Ok 'Modern Standby available - networking in standby is off (debloat\windows.ps1)'
} else {
    Warn 'no sleep state available - if S3 is blocked by the hypervisor, set BIOS Sleep State = Windows (docs\LAPTOP.md, Sleep)'
}
# The Power mode slider only exists under Balanced (or a plan derived from it).
# Ultimate/High Performance hides it - and with it "Best performance when plugged
# in, Balanced on battery" - while running a 15 W CPU hot on battery.
$activeScheme = (powercfg /getactivescheme | Out-String)
if ($activeScheme -match '381b4222-f694-41f0-9685-ff5bb260df2e') {
    Ok 'power plan is Balanced (the Power mode slider works)'
} else {
    Warn "power plan is not Balanced: $($activeScheme.Trim()) - switch back with: powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e"
}
$overlays = @{
    '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency'
    '00000000-0000-0000-0000-000000000000' = 'Balanced'
    '3af9b8d9-7c97-431d-ad78-34a8bfea439f' = 'Balanced'
    'ded574b5-45a0-4f42-8737-46345c09c238' = 'Best performance'
}
$schemes = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
foreach ($source in 'Ac', 'Dc') {
    $guid  = Get-ItemPropertyValue -Path $schemes -Name "ActiveOverlay${source}PowerScheme" -ErrorAction SilentlyContinue
    $label = if ($guid) { $overlays[$guid] ?? $guid } else { 'Balanced (default)' }
    Info ('power mode {0}: {1}' -f ($source -eq 'Ac' ? 'plugged in' : 'on battery'), $label)
}
