# Laptop-only part of tune.ps1. Dot-sourced by it, so it runs in tune.ps1's
# scope and uses its helpers: no param block, no exit.

# ---- Sleep states -----------------------------------------------------------
# Printed, not changed. S3 versus Modern Standby is a BIOS setting, chosen once
# by hand from this output.
Write-Step 'Sleep states (powercfg /a)'
powercfg /a
Write-Host @'

  Reading this on the T490s:
    "Standby (S3)" available         -> keep BIOS Sleep State = Linux. S3 measured
                                        about 2% overnight drain on CachyOS.
    S3 blocked by the hypervisor     -> BIOS Config > Power > Sleep State = Windows
                                        (Modern Standby), and set hibernate-after on
                                        battery in Settings. See docs\LAPTOP.md, Sleep.
'@
