# Laptop: ThinkPad T490s

i5-8365U (4 cores, 15 W) · Intel UHD 620 · **16 GB soldered** · 238 GB NVMe · 1080p panel at 125%.

These are the laptop's own stages. [SETUP.md](SETUP.md) has the shared ones and the order to do them in:

1. SETUP.md stage 0 (backups)
2. Stages 1–2 here
3. SETUP.md stages 2–4 (apps, apply, restore)
4. Stages 3–5 here

The scripts detect this machine as `laptop` from its chassis type.

## 1. BIOS (press F1 at the ThinkPad logo)

| Setting | Value | Why |
|---|---|---|
| Security → Secure Boot | **Enabled**, then *Restore Factory Keys* | Windows 11 requires it. The Linux guide had it off |
| Security → Security Chip | Enabled (Intel PTT, TPM 2.0) | Windows 11 requires it |
| Security → Virtualization | Intel VT-x and VT-d **Enabled** | Docker Desktop's VM needs them |
| Config → Thunderbolt BIOS Assist Mode | Disabled (unchanged) | Windows handles Thunderbolt natively |
| Config → Power → Sleep State | Leave it for now | Decided in stage 4 from `powercfg /a` |

## 2. Install Windows 11 Pro, then the Dev Drive

1. **Partitions.** Delete every partition on the NVMe. Create the Windows partition at about
   **160 GB** (`163840` MB in Setup) and leave the rest **unallocated**, roughly 75 GB. A Dev Drive
   can't be made by converting an existing volume, and shrinking C: later is more work.
2. **Windows Update.** After first sign-in, run *Settings → Windows Update* until nothing is left.
   Then open *Advanced options → Optional updates → Driver updates*, where Lenovo publishes the
   T490s drivers and firmware.
   - Also in *Advanced options*, turn on **Receive updates for other Microsoft products**. That keeps
     the Visual C++ runtimes and .NET patched along with Windows.
   - **Skip Lenovo Vantage.** Its service runs permanently.
3. **Dev Drive.** Go to *Settings → System → Storage → Advanced storage settings → Disks & volumes*,
   select the *Unallocated* space, and choose **Create Dev Drive**. Use letter `D:` and label `Dev`.
   It's marked trusted when created, which puts Defender into performance mode on it. Your projects,
   package caches and the PostgreSQL data all go here, so create it before installing apps.

Now go back to [SETUP.md, stage 2](SETUP.md#2-apps).

## 3. Power

Keep the **Balanced** power plan. In *Settings → System → Power & battery*:
- Set *Power mode* to **Best performance** when plugged in and **Balanced** on battery.
- Set *Energy saver* to 20–30%.

Don't use Ultimate Performance. It hides this slider, and on a 15 W CPU it trades battery and heat for
close to nothing. `doctor.ps1` warns if the active plan isn't Balanced.

## 4. Sleep: S3 or Modern Standby

On CachyOS, S3 sleep measured about **2%** overnight battery drain, against about **15%** for Modern
Standby. Windows 11 turns Memory Integrity on by default, and Docker Desktop's VM needs the
hypervisor. Either one can make S3 unavailable, with the message "The hypervisor does not support
this standby state".

```powershell
powercfg /a
```

`tune.ps1` prints the same output with a short guide.

- **Standby (S3) is listed as available:** keep BIOS *Sleep State* = **Linux**.
- **S3 isn't available:** set BIOS *Sleep State* = **Windows** (Modern Standby).
  - `debloat\windows.ps1` already turned off networking during standby on this machine (the
    laptop profile adds `-DisableModernStandbyNetworking`). That removes most of the drain.
  - Also go to *Settings → Power & battery → Screen, sleep & hibernate timeouts* and set hibernate
    after about 60 minutes on battery.

Leave Memory Integrity on. It's a security feature, not a memory one. (The desktop turns it off,
for reasons that don't apply to a laptop; see [DESKTOP.md](DESKTOP.md#4-memory-integrity-off).)

## 5. Measure

The Linux repo's rule: numbers, not estimates. The last section of `doctor.ps1` prints a memory
breakdown. Take three snapshots and record them here.

| When | Commit | Available | Brave | VS Code | WebView2 | PostgreSQL | Container VM | Compression | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Idle, fresh install (clone the repo, run only the doctor) | | | | | | | | | |
| Idle, after SETUP stage 3 and a restart | | | | | | | | | |
| Normal dev session | | | | | | | | | |

Then set `memory=` in `config\shared\wsl\.wslconfig` from the dev-session row, and re-run `install.ps1`.
The file is shared, so compare with the desktop's table before you change it.
