# Desktop: Ryzen 5 3600 + RX 570

MSI B450M Mortar MAX · Ryzen 5 3600 (6 cores, 12 threads, Zen 2) · Sapphire Radeon RX 570 8 GB
(Polaris) · 16 GB DDR4-2400 · Samsung 970 EVO 500 GB NVMe · Seagate 1 TB 2.5" **5400 RPM** HDD ·
450 W PSU · Realtek RTL8111H ethernet.
**Displays:** Esonic 22ELMW 1920×1080 (right, primary) and Samsung S19F350 1366×768 (left), both at
100%, no FreeSync.

Everything the laptop has, plus games and creative work. The memory rules don't change, because this
machine also has 16 GB. Games get their RAM by stopping the dev stack first (`gameprep`), not by
tuning Windows harder.

These are the desktop's own stages. [SETUP.md](SETUP.md) has the shared ones. The order:

1. SETUP.md stage 0, then stage 0 here, both still on CachyOS
2. Stages 1–4 here
3. SETUP.md stage 2, then stage 5 here, then SETUP.md stages 3–4
4. Stages 6–8 here

The scripts detect this machine as `desktop` from its chassis type. If the board reports "Other" or
"Unknown", they fall back to "no battery", which gives the same answer.

## 0. The HDD: ext4 to NTFS, data kept (on CachyOS, before the wipe)

Today the HDD is ext4, mounted at `/mnt/games`. It holds your personal data in `Storage/` plus the
Linux Steam and Heroic libraries. Windows can't read ext4, so the data makes a round trip through the
NVMe while CachyOS is still there:

1. Copy it off.
2. Verify the copy.
3. Reformat the HDD as NTFS.
4. Copy the data back and verify again.

The games aren't copied: Steam and Epic download them again on Windows.

This follows the Linux repo's migration (`dotfiles-linux/docs/DESKTOP.md`, Phase 2): sha256
manifests on both sides, and nothing is destroyed until they match. Close Steam and Heroic first.

1. **Find the disk and check the space.** Free space on `/home` must be at least **1.2×** the data.

   ```bash
   lsblk -o NAME,SIZE,FSTYPE,LABEL,PTTYPE,MOUNTPOINTS   # the ~931G disk labelled "games"
   du -sh /mnt/games/Storage
   df -h /home
   ```

   Below, `/dev/sdX` is that disk, and `/dev/sdXN` is its partition, number `N`.
2. **Find names Windows can't use**, while the HDD is still writable. ext4 allows names that Windows
   refuses, so rename anything these print:
   - the characters `\ : * ? " < > |`
   - a trailing dot or space
   - reserved names such as `CON` or `NUL`
   - two names in one folder that differ only in case

   ```bash
   cd /mnt/games/Storage
   find . -name '*[\\:*?"<>|]*' -o -name '*.' -o -name '* ' \
          -o -iregex '.*/\(con\|prn\|aux\|nul\|com[1-9]\|lpt[1-9]\)\(\..*\)?'
   find . | sort -f | uniq -di
   ```
3. **Copy off, and verify by content.** An rsync exit code of 0 says the copy finished, not that
   the bytes match. The manifests go in `~`, not `/tmp`: `/tmp` is cleared on reboot.

   ```bash
   mkdir -p ~/Storage-staging
   rsync -aHAX --info=progress2 /mnt/games/Storage/ ~/Storage-staging/
   cd /mnt/games/Storage && find . -type f | LC_ALL=C sort | xargs -d'\n' sha256sum > ~/old.sha256
   cd ~/Storage-staging  && find . -type f | LC_ALL=C sort | xargs -d'\n' sha256sum > ~/new.sha256
   diff ~/old.sha256 ~/new.sha256 && echo "IDENTICAL - safe to reformat"
   ```

   If `diff` prints anything, **stop** and re-run the `rsync`. It's incremental, so the second run is
   cheap.
4. **Reformat as NTFS.** Remove the `/mnt/games` line from `/etc/fstab` too, or the next boot waits
   for an ext4 disk that no longer exists.

   ```bash
   sudo pacman -S --needed ntfs-3g              # provides mkfs.ntfs
   sudo umount /mnt/games
   sudoedit /etc/fstab                          # delete the /mnt/games line
   sudo systemctl daemon-reload
   sudo mkfs.ntfs --fast --label Storage /dev/sdXN
   ```

   Windows only gives a drive letter to a *Microsoft basic data* partition, and this one is still
   typed *Linux filesystem*. `sfdisk` comes with util-linux:

   ```bash
   lsblk -no PTTYPE /dev/sdX                    # gpt or dos
   sudo sfdisk --part-type /dev/sdX N EBD0A0A2-B9E5-4433-87C0-68B6B72699C7   # if gpt
   sudo sfdisk --part-type /dev/sdX N 7                                      # if dos
   ```
5. **Copy back, and verify again.**
   - Use `rsync -rt`, not `-aHAX`: NTFS has no Linux owners or permissions to keep, and `-t` keeps
     modification times.
   - Mount with `windows_names`: the `ntfs3` driver then refuses any name Windows couldn't open, so a
     name missed in step 2 fails loudly here.

   ```bash
   sudo mkdir -p /mnt/storage
   sudo mount -t ntfs3 -o uid=$(id -u),gid=$(id -g),windows_names /dev/sdXN /mnt/storage
   rsync -rt --info=progress2 ~/Storage-staging/ /mnt/storage/Storage/
   cd /mnt/storage/Storage && find . -type f | LC_ALL=C sort | xargs -d'\n' sha256sum > ~/final.sha256
   diff ~/old.sha256 ~/final.sha256 && echo "IDENTICAL" && rm -rf ~/Storage-staging
   ```
6. **Put the Linux backup on it.** Run SETUP.md stage 0's `tar` step with `dest=/mnt/storage`, then
   `sudo umount /mnt/storage` and shut down.

## 1. BIOS (press Delete at the MSI splash)

| Setting | Value | Why |
|---|---|---|
| **M-Flash** (do this first) | The latest BIOS from the [MSI support page](https://www.msi.com/Motherboard/B450M-MORTAR-MAX/support), on a FAT32 USB stick | Newer AGESA fixes the AMD fTPM stutter Windows can hit (fixed from AGESA 1.2.0.7). A flash resets every setting, so the rows below come after it |
| OC → DRAM Setting → A-XMP | **Profile 1** | Without it the DDR4-2400 kit runs at 2133. `doctor.ps1` checks the speed |
| OC → CPU Features → SVM Mode | **Enabled** | AMD virtualization. Docker Desktop's VM needs it |
| Settings → Advanced → Integrated Peripherals → SATA Mode | AHCI | Never RAID |
| Settings → Advanced → Windows OS Configuration → BIOS UEFI/CSM Mode | UEFI | Windows 11 requires it |
| Settings → Advanced → Windows OS Configuration → Secure Boot | **Enabled** (Standard) | Windows 11 requires it. The Linux setup had it off |
| Settings → Security → Trusted Computing → AMD fTPM switch | **AMD CPU fTPM** | TPM 2.0 for Windows 11 |
| Settings → Advanced → Wake Up Event Setup | Wake from USB off | Otherwise a mouse nudge wakes the PC |

## 2. Install Windows 11 Pro, then G: and the Dev Drive

1. **Unplug the HDD's SATA data cable.** It holds the only copy of `Storage`. Windows Setup can't
   touch a disk it can't see. Install over ethernet.
2. **Partitions.** Delete every partition on the NVMe. Create the Windows partition at about
   **390 GB** (`399360` MB in Setup) and leave the rest **unallocated**, roughly 75 GB, for the Dev
   Drive.
3. **Windows Update.** Run it until nothing is left. In *Advanced options*, turn on **Receive updates
   for other Microsoft products**. Drivers come in stage 3.
4. **Plug the HDD back in** (shut down first). It gets the next free letter, which would be D:. Open
   *Disk Management* (`diskmgmt.msc`), right-click the *Storage* volume → *Change Drive Letter and
   Paths* → **G:**. Do this before the Dev Drive, so D: stays free for it.
5. **Dev Drive.** Go to *Settings → System → Storage → Advanced storage settings → Disks & volumes*,
   select the NVMe's *Unallocated* space, and choose **Create Dev Drive**. Use letter `D:` and label
   `Dev`. It's trusted when created, so Defender runs in performance mode on it.

Games don't go on the Dev Drive: it's sized for code, package caches and PostgreSQL. Every library
goes on G: (stage 5).

## 3. Drivers

Windows Update installs working drivers for most of the board. Replace the ones that matter with the
vendors' own.

1. **Motherboard**, from [MSI's B450M MORTAR MAX support page](https://www.msi.com/Motherboard/B450M-MORTAR-MAX/support)
   → *Driver*, Windows 11 64-bit:
   - **AMD Chipset Driver**, first: Ryzen power management and the PSP/fTPM drivers
   - **Realtek LAN** (RTL8111H)
   - **Realtek HD Audio**

   Skip *MSI Center*, the *Driver Utility Installer* and the other utilities. Each adds a service
   that runs all day.
2. **GPU: AMD Software: Adrenalin Edition**, from [amd.com/support](https://www.amd.com/en/support/download/drivers.html)
   → Graphics → Radeon RX 500 Series → RX 570. The RX 570 is on AMD's **Polaris & Vega** legacy
   branch, a separate download from the newest Adrenalin. Choose **Full Install**, then use it for
   tuning only:
   - *Performance → Tuning*: switch to manual tuning. Set the **fan curve** under *Fan Tuning* and the
     **power limit** under *Power Tuning*, then save it as a profile.
   - *Settings*: turn off the in-game overlay, notifications and advertisements, *Instant Replay* and
     desktop recording (OBS and Recordly do the recording), and AMD Link.
   - Leave AMD Software's startup entry **on**. It's what applies the tuning profile after sign-in.
     Restart once and check that the fan curve held.
   - Windows names the card **Radeon RX 570**. The old "RX 580X" name came from a modded setup; the
     official driver doesn't use it.

**One tuner.** Adrenalin owns the fan curve and power limit. Don't add MSI Afterburner or FanControl
on top: two tools writing the same settings undo each other, and `doctor.ps1` warns if either shows
up. The same goes for PowerPlay table edits and modded drivers. On Linux, forcing `amdgpu.ppfeaturemask`
for this kind of control caused trouble and was removed.

## 4. Memory Integrity off

Memory Integrity (hypervisor-protected code integrity) makes the hypervisor check kernel-mode code.
Windows 11 turns it on by default. On this machine it's turned off **by hand**, for game performance.
Zen 2's GMET keeps the cost low, but it isn't zero. The laptop keeps it on.

WSL 2 and Docker Desktop don't depend on it. They run on the *Virtual Machine Platform*, which stays
on, and `doctor.ps1` checks that WSL still responds.

1. *Windows Security → Device security → Core isolation details* → **Memory integrity: Off**.
   Windows Security will keep showing a warning about it.
2. Restart.
3. From an elevated terminal, run `pwsh -File .\scripts\doctor.ps1`. It should report *Memory
   Integrity off* and *wsl --status responds*.

No script here does this, on purpose: the scripts report security settings and never change them.

## 5. Desktop apps

Do this after SETUP.md stage 2. The same rule applies: the Microsoft Store if the app is there,
otherwise the vendor's self-updating installer.

| App | Source | Notes |
|---|---|---|
| Steam | [store.steampowered.com/about](https://store.steampowered.com/about/) | Updates itself |
| Epic Games Launcher | [store.epicgames.com/download](https://store.epicgames.com/download) | Updates itself |
| Affinity | Microsoft Store, `9NW9CX6H2JGL` | Updated by the Store |
| Recordly | [recordly.dev](https://recordly.dev/) | |
| SKLauncher | [skmedix.pl](https://skmedix.pl/) | Bundles its own Java |

### Steam

- *Settings → Storage → Add Drive → G:*. That creates `G:\SteamLibrary`; make it the default.
- *Settings → Interface*: turn off *Run Steam when my computer starts* and *Enable GPU accelerated
  rendering in web views*.
- *Settings → Library*: turn on *Low Performance Mode*.

`steamwebhelper` is Chromium, one process per view; these settings keep it small while a game runs.

### Epic Games Launcher

- *Settings*: turn off *Run When My Computer Starts* and *Minimize To System Tray*, so closing the
  window really exits.
- Epic asks where to install **every time**. Change it to `G:\Epic Games` each time; the default is
  `C:\Program Files`.

### Affinity

*Settings → Performance*: leave hardware acceleration on (the RX 570 supports Direct3D 12 feature
level 12.0). Keep the RAM limit well under 16 GB, so Brave and the rest have room.

### Recordly and OBS Studio

- **Recordly:** save recordings to `G:\Recordings`.
- **OBS** (installed in SETUP.md stage 2): in *Settings → Output*, set the encoder to **AMD HW H.264
  (AVC)** so the RX 570 does the encoding instead of the CPU, and the recording path to
  `G:\Recordings`.

### SKLauncher (Minecraft)

Set the game directory to G:, for example `G:\Minecraft`, and memory to **4 GB** per profile. More
doesn't make vanilla faster; a large modpack may want 6 GB.

### Startup apps

In *Settings → Apps → Startup*, turn off Steam, Epic Games Launcher, SKLauncher and Recordly. Leave
**AMD Software** on (stage 3). `doctor.ps1` warns when any of the launchers come back.

## 6. Power and displays

**Power.** Keep **Balanced** (or *AMD Ryzen Balanced*, if the chipset driver added it). Set
*Settings → System → Power → Power mode* to **Best performance**. Don't use Ultimate Performance: it
removes the Power mode slider and keeps cores out of their idle states, which buys heat and fan
noise rather than frames. `tune.ps1` has already turned hibernation off; sleep still works.

**Displays.** In *Settings → System → Display*, click *Identify* and arrange them: the 1366×768 on the
left, the 1920×1080 on the right. Select the right one and choose *Make this my main display*. Set
both to **100%**.

## 7. Gaming notes

- **Run `gameprep` before a game.** It stops PostgreSQL, Docker Desktop and the WSL VM, then shows
  `mem`. That hands back up to the VM's 4 GB cap, plus PostgreSQL. Bring them back later with
  `pgstart` and Docker Desktop from the Start menu.
- **Game Mode stays on** (*Settings → Gaming → Game Mode*); `tune.ps1` reports it. The Xbox app and
  Game Bar are removed by `debloat\windows.ps1`, and Game Mode doesn't need them.
- **Upscaling.** Polaris gets neither Radeon Super Resolution nor hardware-accelerated GPU
  scheduling, so use each game's own **FSR** setting.
- **Frame caps.** Neither monitor has FreeSync, so cap the frame rate in the game if it runs hot or
  uneven.
- **Close Brave, don't minimize it.** With background mode off (SlimBrave Neo), closing actually
  frees its memory.
- **The 450 W PSU.** A 3600 (65 W) plus an RX 570 (about 150 W, with higher spikes) peaks around
  330 W. A healthy unit has the headroom. If the PC **reboots** under load instead of crashing,
  suspect the PSU before the GPU.

## 8. Measure

The last section of `doctor.ps1` prints a memory breakdown, with rows for Steam, Epic, Minecraft,
Affinity, OBS, Recordly and Adrenalin on this machine. Record four snapshots:

| When | Commit | Available | Brave | VS Code | WebView2 | PostgreSQL | Container VM | Compression | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Idle, fresh install (clone the repo, run only the doctor) | | | | | | | | | |
| Idle, after SETUP stage 3 and a restart | | | | | | | | | |
| Normal dev session | | | | | | | | | |
| Game running, after `gameprep` | | | | | | | | | Launcher and game rows |

`.wslconfig` is shared with the laptop. If this machine's dev session needs a different `memory=`,
compare it with [LAPTOP.md stage 5](LAPTOP.md#5-measure) before changing
`config\shared\wsl\.wslconfig`.
