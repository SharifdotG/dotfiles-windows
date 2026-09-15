# dotfiles-windows

Windows 11 Pro on two machines. Both have **16 GB of RAM** and run Docker, Angular/Nx, .NET with
PostgreSQL, and a browser at the same time.

| | Laptop | Desktop |
|---|---|---|
| Machine | ThinkPad T490s | MSI B450M Mortar MAX |
| CPU | i5-8365U (4 cores, 15 W) | Ryzen 5 3600 (6 cores, 65 W) |
| GPU | Intel UHD 620 | Radeon RX 570 8 GB (Polaris) |
| RAM | 16 GB, **soldered** | 16 GB DDR4-2400 |
| Storage | 238 GB NVMe | 512 GB NVMe + 1 TB HDD as `G:` |
| On top of the shared setup | Sleep-state and battery tuning | Games, recording and creative apps |
| Runbook | [docs/LAPTOP.md](docs/LAPTOP.md) | [docs/DESKTOP.md](docs/DESKTOP.md) |

This is the Windows counterpart of `dotfiles-linux` (CachyOS + KDE Plasma). It carries over that
repo's one *measured* lesson: the memory goes to **the browser, the containers and the apps that
start themselves**, not to the desktop. The entire Plasma session measured 0.58 GiB; the browser
measured 8.13 GiB. So the effort here goes into those three, and almost none into the Windows shell.

It is deliberately **not** an installer:

- **Apps** come from the Microsoft Store, which keeps them updated, or from official installers that
  update themselves. [docs/SETUP.md](docs/SETUP.md) has the checklist.
- **Debloating** uses two maintained tools, [Win11Debloat](https://github.com/Raphire/Win11Debloat)
  and [SlimBrave Neo](https://github.com/ChaoticSi1ence/SlimBrave-Neo). Both are pinned to the
  releases this repo was checked against, rather than a home-grown list of registry keys.

> `dotfiles-linux/` sits in this folder as a read-only reference and is gitignored.

## Run order

The same on both machines. Run these on a fresh install, after Windows Update is clean and the apps
in `docs/SETUP.md` are installed. [docs/SETUP.md](docs/SETUP.md) has the full sequence, including
what to back up before wiping Linux.

```powershell
pwsh -File .\debloat\windows.ps1          # admin (self-elevates); makes a restore point first
pwsh -File .\tune.ps1                     # admin (self-elevates)
pwsh -File .\install.ps1 -DevDrive D:     # user; add -WhatIf to preview
Restart-Computer
pwsh -File .\debloat\brave.ps1            # opens SlimBrave Neo: Import the preset, Apply
pwsh -File .\scripts\doctor.ps1           # verify. Run it once elevated as well
```

- Every script can be re-run safely, and each one prints `Profile: laptop` or `Profile: desktop`
  first.
- `install.ps1` is also how you apply edits made under `config\`.
- `debloat\windows.ps1` can be re-run whenever a Windows feature update reinstalls removed apps.
- `pwsh` works the same with PowerShell Preview from the Microsoft Store, which registers `pwsh.exe`
  too.

## How the two machines are told apart

`lib\profile.ps1` decides, and the first answer wins:

1. `-Profile laptop` or `-Profile desktop`, which every script accepts.
2. The `DOTFILES_PROFILE` environment variable.
3. The SMBIOS chassis type (`Win32_SystemEnclosure`). Notebook, laptop, convertible and tablet types
   mean laptop; desktop, tower, all-in-one and mini PC types mean desktop.
4. If the board reports neither, which is common on retail motherboards: a battery means laptop,
   no battery means desktop.

Chassis type is checked before the battery because a desktop on a UPS reports a battery. That's the
same order `dotfiles-linux` uses. The hostname is never used: the repo is public, and matching on
hostnames would publish them.

The scripts that elevate themselves pass the resolved `-Profile` to the elevated window, which starts
with a fresh environment.

| | Shared (both) | Laptop adds | Desktop adds |
|---|---|---|---|
| `install.ps1` | Every file in `config\shared\targets.ps1`, env vars, PATH, git identity | — | `gameprep` (`profile.d\machine.ps1`) |
| `debloat\windows.ps1` | Apps and settings | `-DisableModernStandbyNetworking` | — |
| `tune.ps1` | Compression, SysMain, pagefile, long paths, crash dumps, PostgreSQL Manual | Sleep-state guide | Hibernation off; reports Memory Integrity, Game Mode and the power plan |
| `doctor.ps1` | Everything above, Secure Boot and its 2023 certificate, and where the RAM is | Sleep states, power plan, AC/DC power modes | RAM speed, SVM, the `G:` HDD, hibernation, power plan, display resolutions, Memory Integrity, WSL, BitLocker off, one GPU tuner; memory rows for Steam, Epic, SKLauncher, Recordly, Affinity, OBS, Adrenalin |

## What's here

| Path | Purpose |
|---|---|
| `install.ps1` | Copies the config files into place, backing up anything it replaces. Also creates `~\.gitconfig` with your name and email if it doesn't exist yet, sets user environment variables, adds `%LOCALAPPDATA%\Programs\bin` and `%USERPROFILE%\.local\bin` (Claude Code) to PATH, and sets the desktop wallpaper |
| `tune.ps1` | Memory compression (and keeping SysMain on, which it needs), a system-managed pagefile, long paths, small crash dumps, and PostgreSQL set to start manually. Then `tune\<profile>.ps1` |
| `debloat\windows.ps1` | Runs the pinned Win11Debloat silently, with an explicit list of settings and apps, plus the profile's extra switches |
| `debloat\brave.ps1` | Downloads the pinned, checksum-verified SlimBrave Neo and its "Performance Focused" preset |
| `lib\profile.ps1` | Profile detection (`Get-DotfilesProfile`) and the merged config (`Get-DotfilesConfig`) |
| `config\shared\targets.ps1` | Where each shared config file goes, and which environment variables get set. `install.ps1` and `doctor.ps1` both read it |
| `config\shared\` | PowerShell profile, Windows Terminal (stable and Preview), git, Starship, bat, Docker engine, WSL |
| `config\shared\wallpaper\wallpaper.jpg` | The desktop wallpaper. `install.ps1` copies it to `%LOCALAPPDATA%\dotfiles\` and points Windows at that copy, Fill-style |
| `config\shared\office\configuration.xml` | Office Deployment Tool config: Word, Excel and PowerPoint, with no OneNote, OneDrive, Outlook or bundled Teams |
| `config\shared\postgresql\tuning.sql` | Memory limits for the native PostgreSQL used by nopCommerce |
| `lib\json.ps1` | Reads JSON-with-comments and compares only the keys this repo sets, for the config files their own programs rewrite |
| `config\laptop\profile.ps1`, `config\desktop\profile.ps1` | What each machine adds: files, debloat switches, memory-table rows. Data only |
| `config\desktop\powershell\machine.ps1` | `gameprep`: stops PostgreSQL, Docker Desktop and WSL before a game |
| `tune\laptop.ps1`, `tune\desktop.ps1` | The machine-specific end of `tune.ps1` |
| `scripts\doctor.ps1` | Read-only. Checks the tuning is actually in effect and shows where the RAM is going |
| `scripts\doctor\laptop.ps1`, `scripts\doctor\desktop.ps1` | The machine-specific checks |
| `docs\SETUP.md` | The shared runbook: pre-wipe backup, apps, apply, restore |
| `docs\LAPTOP.md`, `docs\DESKTOP.md` | Each machine's BIOS, install, drivers, power and measurements. The desktop's also covers the HDD's ext4-to-NTFS move, Memory Integrity and gaming |
| `migrate/backup.sh` | Bash, run on the laptop's CachyOS before the wipe. Puts the named projects' (`-p`) local-only files, their databases and volumes, MCP servers, skills and Claude sessions into one checksummed folder. Reuses `dotfiles-linux`'s `db-backup.sh` and `agents-backup.sh` |
| `migrate\restore.ps1` | Run on Windows, on both machines, from that same folder. Verifies it, clones the projects into `D:\Code`, restores their data, and puts Claude Code back under the Windows paths |

## Memory: what replaced each Linux layer

| On CachyOS | On Windows | Where |
|---|---|---|
| zram (zstd, 3.8:1 measured) with `vm.swappiness=180` | Memory compression and page combining on; app pre-launch off; pagefile system-managed | `tune.ps1` |
| `browser.slice` with `MemoryHigh=6G` | Brave policies: background mode off, so Brave exits with its last window. Memory Saver on. Rewards, Wallet, VPN, Leo, News and telemetry off | `debloat\brave.ps1` |
| `docker.socket`: dockerd costs nothing until something uses it | Docker Desktop doesn't start at sign-in. Its VM is capped at 3 GB, hands page cache back when idle, and its disk shrinks | `config\shared\wsl\.wslconfig`, SETUP stage 3 |
| The Postgres container only ran with its stack | The native PostgreSQL service is Manual: `pgstart` and `pgstop` in the profile. `tuning.sql` caps its memory. Its data sits on the Dev Drive | `tune.ps1`, `config\shared\postgresql` |
| earlyoom and systemd-oomd | Nothing on the Windows side, by choice. A runaway container stack hits the VM cap instead of pushing Windows into the pagefile | `config\shared\wsl\.wslconfig` |
| No autostart for Vesktop and Telegram (~700 MB, the biggest single win) | Teams, WhatsApp, Telegram, the AI desktop apps, Vesktop and Docker Desktop off in Startup apps; on the desktop, the game launchers too. `doctor.ps1` flags any that come back | SETUP stage 3, DESKTOP stage 5, doctor |
| Akonadi, Baloo and PackageKit removed or masked | Widgets, Copilot, Recall, Bing, suggestions, telemetry, Game Bar, Delivery Optimization, OneDrive, new Outlook and consumer apps removed or disabled. Office installs without OneNote, OneDrive or Outlook | `debloat\windows.ps1`, `config\shared\office` |
| gamemode on the desktop | Game Mode on, and `gameprep` hands the VM and PostgreSQL memory back before a game | DESKTOP stage 7, `config\desktop` |
| `NODE_OPTIONS`, `NX_DAEMON` and `DOTNET_gcServer` in `.zshrc` | The same values, as persistent user environment variables, so IDEs inherit them too | `config\shared\targets.ps1` |
| VS Code watcher and search excludes; tsserver capped at 3 GB | Not carried here — VS Code's own Settings Sync does it | VS Code, signed in with GitHub |
| `fs.inotify.max_user_watches` | Nothing to raise. On Windows the cost of huge file trees is Defender scanning them, so projects, package caches and the PostgreSQL data go on a **Dev Drive**: ReFS, trusted, which puts Defender in performance mode | LAPTOP/DESKTOP stage 2, `install.ps1 -DevDrive` |

**Why the VM cap is 3 GB.** Native builds (Node, Nx, .NET) and PostgreSQL run on Windows; only the
containers live in the VM. Both machines have 16 GB, and the laptop's can't be upgraded. The cap is
a ceiling, not a reservation, but it also bounds the VM's page cache, which isn't handed back while
a container is running. A 376 MB stack was measured holding 3.3 GB under the old 4 GB cap. 2 GB is
too tight: the VM's own overhead is ~0.4 GB and Keycloak alone wants ~0.6 GB. If the stack you
actually run needs more, raise it and re-measure with `doctor.ps1`.

## Things not to "fix"

- **Don't switch to the Ultimate Performance power plan** (`powercfg -duplicatescheme
  e9a42b02-...`). It removes the Power mode slider, which only exists under Balanced. Its settings
  keep cores out of idle states, which means heat: on the 15 W laptop that means throttling, and on
  the desktop it means fan noise, not frames. Microsoft also hides it on battery-powered machines.
  Use Balanced with *Power mode* set to Best performance. `doctor.ps1` warns about High and Ultimate
  Performance on both machines.
- **Don't let Wintoys change what `tune.ps1` sets.** Its *Performance* page can turn on Ultimate
  Performance and switch off Superfetch/SysMain, and its *Services* page can disable services. Use it
  for health checks, repairs, cleanup and reviewing apps.
- **Don't disable SysMain.** It runs the memory compression store. "Disable SysMain to save RAM"
  guides quietly turn compression off. So does WinUtil's *Set Services to Manual* tweak, which
  includes SysMain; that's why this repo has `tune.ps1` instead of a WinUtil preset.
- **Don't disable or shrink the pagefile.** It sets the commit limit. Browsers, Node, .NET and games
  reserve far more memory than they touch. Without pagefile headroom, allocations fail while Task
  Manager still shows free RAM.
- **Don't remove WebView2.** Teams, WhatsApp and Widgets all run on it. Since late 2025 WhatsApp is
  a WebView2 wrapper around WhatsApp Web.
- **Don't turn off animations or transparency to save memory.** On Linux, the same idea (turning
  off KWin's blur and effects) measured a saving of single-digit MB.
- **Don't set `autoMemoryReclaim=gradual`.** It is known to hang with systemd and to conflict with
  Docker Desktop's Resource Saver. Use `dropCache`.
- **Don't hard-cap Brave with a Job Object.** Windows has nothing like `MemoryHigh`'s throttling. A
  job memory limit behaves like `MemoryMax`: allocations simply fail, and because every process is
  named `brave.exe`, that can take down the whole browser. The Linux repo rejected `MemoryMax` for
  exactly this reason.
- **Don't add `-DisableBraveBloat` to the Win11Debloat call.** SlimBrave Neo owns Brave's policies
  here. With two tools writing the same keys, one tool's *Reset* undoes the other's settings.
- **Don't delete `~\.gitconfig`.** Without it, `git config --global` writes into the managed
  `~\.config\git\config`, and the next `install.ps1` run throws those changes away.
- **Don't add a second GPU tuner on the desktop.** Adrenalin owns the RX 570's fan curve and power
  limit. MSI Afterburner, FanControl, PowerPlay table edits and modded drivers all fight it for the
  same settings. The Linux repo removed its forced `amdgpu.ppfeaturemask` for the same reason.
  `doctor.ps1` warns about a second tuner.
- **Don't let Windows Setup see the desktop's HDD.** Unplug it for any reinstall. `G:\Storage` is the
  only copy of that data.
- **Don't script Memory Integrity, and don't turn it off on the laptop.** Turning it off is a
  manual, desktop-only choice (DESKTOP stage 4). The scripts only report it.
- **Don't let BitLocker stay on on the desktop.** Windows 11 can switch device encryption on during
  setup. It's turned off by hand (DESKTOP stage 2), so a BIOS flash never stops at a recovery-key
  prompt and `G:` is never encrypted. `doctor.ps1` reports it and doesn't change it.
- **Don't use a hostname to pick the profile.** See "How the two machines are told apart".

## Things that write over your files

| Program | Writes | Handling |
|---|---|---|
| Windows Terminal (stable and Preview) | Its whole `settings.json`, stripping comments, whenever you change a setting in its UI | Edit `config\shared\windows-terminal\settings.json` and re-run `install.ps1`, or copy the live file back into the repo |
| Docker Desktop | `~\.docker\daemon.json`, from *Settings → Docker Engine* | Same |

Those four are compared **semantically**, not byte for byte: `doctor.ps1` parses both sides
(comments and trailing commas included) and reports only the settings this repo sets that are no
longer in force, naming each one — `profiles.defaults.font.face`, say. Reformatting, key order and
anything the app added on its own are not drift, which is why a file these programs rewrite can
still read `ok`. `config\shared\targets.ps1` marks them with `Compare = 'JsonSubset'`; the machinery
is `lib\json.ps1`. Every other managed file is still compared by hash, because nothing rewrites it.
| `git config --global`, GitHub Desktop | `~\.gitconfig` | Never touched by `install.ps1` after it creates the file. Git reads it after the managed `~\.config\git\config`, so its values win |
| Windows feature updates | Reinstall some removed apps | Re-run `debloat\windows.ps1`. `doctor.ps1` reports which apps came back |
| Office setup and updates | OneDrive, if installed without `configuration.xml` | Re-run the Office Deployment Tool with `configuration.xml`, then `debloat\windows.ps1`. `doctor.ps1` flags OneDrive, OneNote and Outlook |

## Credentials

No tokens, keys or credential helpers are stored here.
- **Command-line git:** Git for Windows installs **Git Credential Manager** for all users, and GCM
  keeps what it gets in Windows Credential Manager — once per host, for the whole Windows user.
  GitHub gets a browser sign-in; a self-hosted Gitea is not one of the four hosts GCM knows, so it
  shows a username/password box instead — give it a Gitea access token. Being signed in to the host
  in your browser does not count: GCM does not read browser cookies. Details in
  [docs/SETUP.md](docs/SETUP.md), stage 4.
- **GitHub Desktop:** signs in on its own, and covers what the GitHub CLI would — `gh` is
  deliberately not part of this setup.
- **Identity:** `~\.gitconfig` (your name and email). `install.ps1` creates it only if it is missing,
  so if GitHub Desktop already wrote one, it is left alone and you are never prompted. Not part of
  the repo either way.

## Notes

- **Docker Desktop licence.** It's free for personal use, education, and businesses with under 250
  employees **and** under $10M revenue. Anything else needs a paid plan.
- **VS Code is deliberately not managed here.** Its Settings Sync, signed in with a GitHub account,
  already carries settings, keybindings and extensions between machines, and rewrites them whenever
  it syncs — so a copy in this repo would be a second owner fighting the first. Nothing to install,
  nothing to back up, nothing to restore.
- **Win11Debloat's default app list removes the new Teams.** `debloat\windows.ps1` keeps it. If you
  ever run Win11Debloat by hand with `-RunDefaults`, Teams goes.
- **Windows Terminal's `profiles.list` must not be empty.** Terminal does not fill it in for you: an
  empty list means no profile, and it refuses to load the file at all ("All profiles were hidden in
  your settings"), falling back to its own defaults. The repo's `settings.json` therefore lists
  PowerShell 7 and the two inbox profiles by their fixed GUIDs, and Terminal adds the ones it
  generates (Git Bash, WSL, Visual Studio) on top.
- **Windows Terminal's `defaultProfile` fails silently.** Terminal generates the PowerShell 7 profile
  from whatever `pwsh.exe` it finds — the Store's PowerShell Preview included — and current builds
  name it plain **`PowerShell`**; older builds used `PowerShell Preview (msix)`. A `defaultProfile`
  matching no profile is not an error: Terminal opens Windows PowerShell 5.1 instead, which reads a
  different profile directory, so none of this repo's shell config applies. `doctor.ps1` now checks
  that the name resolves.
- **The Nerd Font family was renamed.** Nerd Fonts v3.4 shortened `CaskaydiaCove Nerd Font` to
  `CaskaydiaCove NF`. A `face` naming a font that isn't installed also falls back without an error,
  so the Terminal and VS Code configs list both spellings and then `Cascadia Mono`.
