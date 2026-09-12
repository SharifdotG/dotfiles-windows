# Setup runbook: Windows 11 Pro on the laptop and the desktop

A one-time sequence for each machine, from CachyOS to Windows 11 Pro. This file has the stages both
machines share. Hardware stages live in each machine's own file:

| Machine | File | The scripts detect it as |
|---|---|---|
| ThinkPad T490s | [LAPTOP.md](LAPTOP.md) | `laptop` |
| Ryzen 5 3600 + RX 570 desktop | [DESKTOP.md](DESKTOP.md) | `desktop` |

The order:

1. **Stage 0** here, on CachyOS. On the desktop, DESKTOP.md stage 0 (the HDD) follows straight after.
2. **Stage 1:** the machine file's BIOS, install and driver stages.
3. **Stages 2–4** here: apps, apply, restore. The desktop adds its own apps (DESKTOP.md stage 5)
   after stage 2, and skips `restore.ps1`: it starts fresh.
4. The rest of the machine file: power, then measure.

Stage 0 is the only one that can't be redone.

## 0. Before the wipe (on CachyOS)

Everything below exists only on the disk you're about to erase.

### The one-command backup

**The desktop skips `backup.sh`.** Windows starts fresh there, nopCommerce included, and DESKTOP.md
stage 0 copies the data to the HDD.

From this repo's checkout:

```bash
./migrate/backup.sh                       # laptop only: SocialHousingOSS and structflow by default
```

Each run writes a new `~/Backup/windows-migration/<timestamp>/`. Where the Linux repo's backup
scripts already do a job, `backup.sh` runs them:

| Folder | Holds | Made by |
|---|---|---|
| `projects/` | Each project's files that git doesn't carry (`.env`, `docker-compose.override.yml`, untracked files), minus rebuildable folders such as `node_modules`; its remote and branch | `git ls-files` |
| `db/` | Every Postgres database as a `pg_dump`, one per database; the other named volumes as tarballs | `db-backup.sh` |
| `agents/` | Global MCP servers with their keys, skills, settings, rules, the plugin list | `agents-backup.sh export` |
| `claude/` | Claude Code transcripts, memory, plans, prompt history and rewind checkpoints; Claude Desktop's Code-tab session list | `tar` |
| `SHA256SUMS` | A checksum for every file. `restore.ps1` checks them before it changes anything | `sha256sum` |

- It warns about uncommitted edits, unpushed branches and stashes, because those aren't in it. Push
  them, then run it again.
- Containers that use a volume stop for a moment while it's copied, then start again.
- More projects: `-p SocialHousingOSS -p structflow -p <another>`. `-p` replaces the default list.
- **It holds secrets:** `.env` files and MCP API keys. It's created `0700`; keep it off every repo, and
  in two places. `~/.claude/.credentials.json` is left out on purpose: you sign in again.
- If you keep working after it runs, run it again right before the wipe.

### By hand

The rest of `dotfiles-linux/docs/MIGRATION.md`, stages 2 and 3:

- [ ] Push every repo.
- [ ] In the other repos, sweep for gitignored secrets beyond `.env`: `appsettings.Development.json`,
  dev certs, `*.pfx`, `docker-compose.override.yml`. `backup.sh` already covers its own projects.
- [ ] Write down the Brave Sync code (24 words) and your 2FA recovery codes somewhere that isn't
  this machine.
- [ ] Copy everything to a drive that survives the wipe **as a single tar file**. An exFAT or NTFS
  drive can't store Linux permissions or symlinks, but a tar file on that drive preserves them.
  - **Laptop:** an external drive.
  - **Desktop:** the HDD, after DESKTOP.md stage 0 has turned it into NTFS. It stays unplugged while
    Windows installs, so Setup never sees it.

  ```bash
  dest=/run/media/$USER/<drive>             # desktop: /mnt/storage, from DESKTOP.md stage 0
  tar -cpf "$dest/linux-backup.tar" -C ~ Backup Documents
  tar -tf  "$dest/linux-backup.tar" | head  # prove it reads back
  ```
- [ ] Make the Windows 11 USB (next section).

### Windows 11 USB

Writing Microsoft's ISO with `dd` doesn't give a bootable stick, and a plain copy fails too:
`sources/install.wim` is bigger than FAT32's 4 GB file limit (7.98 GB in the 25H2 ISO), while UEFI
firmware boots from FAT32. So:
- Make a FAT32 stick.
- Split that one file into parts, which Windows Setup reads natively.

It boots with Secure Boot on, using only Microsoft's own boot loader. Use a **16 GB or larger** stick
and an ISO from [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11).

```bash
sudo pacman -S --needed wimlib
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS         # the stick shows TRAN usb; below it is /dev/sdX
sudo umount /dev/sdX1 2>/dev/null                  # only if KDE mounted it
sudo wipefs --all /dev/sdX                         # ERASES the stick - check the letter twice
sudo parted --script /dev/sdX mklabel gpt mkpart WIN11 fat32 1MiB 100%
sudo mkfs.fat -F 32 -n WIN11 /dev/sdX1
sudo mkdir -p /mnt/iso /mnt/usb
sudo mount -o loop,ro ~/Downloads/<windows-11>.iso /mnt/iso
sudo mount /dev/sdX1 /mnt/usb
sudo rsync -r --info=progress2 --exclude=/sources/install.wim /mnt/iso/ /mnt/usb/
sudo wimlib-imagex split /mnt/iso/sources/install.wim /mnt/usb/sources/install.swm 3800
ls -lh /mnt/usb/sources/install*.swm               # install.swm, install2.swm, install3.swm
sync && sudo umount /mnt/usb /mnt/iso              # sync can take minutes on a slow stick
```

Boot it from the one-time boot menu: **F12** on the ThinkPad, **F11** on the MSI board. Ventoy
(`ventoy-bin`) works too, but with Secure Boot on, each PC first needs a one-time key enrollment.

## 1. The machine: BIOS, Windows, drivers, Dev Drive

- **Laptop:** [LAPTOP.md](LAPTOP.md), stages 1–2.
- **Desktop:** [DESKTOP.md](DESKTOP.md), stages 1–4.

Both end with a `D:` Dev Drive of about 75 GB, created before any app is installed. Projects, package
caches and the PostgreSQL data all go there.

## 2. Apps

Everything the scripts use is checked for first, so a missing app produces a warning, not a failure.
Prefer the Microsoft Store where an app is there, since the Store updates it. Otherwise use the
vendor's own installer. Both machines get everything below; the desktop adds its games and creative
apps in [DESKTOP.md stage 5](DESKTOP.md#5-desktop-apps).

### From the Microsoft Store

Updated by the Store. Check that *Store → your profile → Settings → App updates* is on.

| App | Notes |
|---|---|
| PowerShell Preview | Registers `pwsh.exe`. Windows Terminal generates its profile from this and names it plain **PowerShell** — that exact name is what `defaultProfile` points at (see "The two silent failures" below) |
| Windows Terminal Preview | Then set *Settings → System → For developers → Terminal* to **Windows Terminal Preview** |
| Python Install Manager | The way python.org now ships Python on Windows. It puts `python`, `py` and `pip` shims in `%LOCALAPPDATA%\Python\bin` (already on PATH) and the runtimes under `%LOCALAPPDATA%\Python\pythoncore-<version>`. Install a runtime with `py install 3` |
| ChatGPT | The Store build, not the openai.com download. It installs under the package identity **`OpenAI.CodexBeta`** — that is the ChatGPT app, not the Codex CLI below; `Get-AppxPackage` and `winget list` both show that name |
| Microsoft Teams | Kept by `debloat\windows.ps1` on purpose |
| WhatsApp Beta | A WebView2 wrapper around WhatsApp Web, so it isn't light. Keep its autostart off |
| Screenbox Media Player | Optional — a media player, nothing depends on it |
| Wintoys | Use it for health checks, repairs and cleanup. **Not** its Ultimate Performance or Superfetch toggles, and not its service disabling (README, "Things not to fix") |

### Runtimes (Microsoft)

| Runtime | Source | Notes |
|---|---|---|
| Visual C++ Redistributable Runtimes, all-in-one | [techpowerup.com](https://www.techpowerup.com/download/visual-c-redistributable-runtime-package-all-in-one/) | One run installs every runtime from 2005 to 2022, x86 **and** x64. Apps link against whichever version they were built with, and plenty are still 32-bit. Microsoft's own [permalinks](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) cover only v14 (2015-2022) |
| DirectX End-User Runtime | [Microsoft Download Center, id 35](https://www.microsoft.com/download/details.aspx?id=35) | Adds the legacy D3DX9/10/11, XAudio 2.7 and XInput 1.3 libraries some older apps expect. It doesn't change the DirectX version |
| .NET SDK 9 and 10 | [dotnet.microsoft.com/download](https://dotnet.microsoft.com/download) | Patched through Microsoft Update (stage 1) |

### Official installers

Most of these update themselves from inside the app. **The first three are in order**; the rest can
follow in any order.

| App | Source | Notes |
|---|---|---|
| Brave | [brave.com/download](https://brave.com/download/) | **1st.** Edge is the only browser on a fresh install, so getting Brave in place first means every download below happens in the browser you actually keep |
| VS Code Insiders | [code.visualstudio.com/insiders](https://code.visualstudio.com/insiders/) | **2nd**, before Git: Git's installer only offers "Use Visual Studio Code as Git's default editor" if it is already there. Keep "Add to PATH" |
| Git for Windows | [git-scm.com/downloads/win](https://git-scm.com/downloads/win) | **3rd.** Keep **Git Credential Manager**. Editor: VS Code Insiders. Line endings: **Checkout as-is, commit as-is**. Claude Code uses its Git Bash for the Bash tool |
| GitHub Desktop | [desktop.github.com](https://desktop.github.com/) | Updates itself. Signs in on its own, and covers what the GitHub CLI would - so `gh` is deliberately not installed here |
| Docker Desktop | [docs.docker.com/desktop/setup/install/windows-install](https://docs.docker.com/desktop/setup/install/windows-install/) | Use the WSL 2 backend — its installer pulls in **WSL** if it isn't there, and creates a `docker-desktop` distro; nothing else here needs a WSL distro of your own. **Licence:** free only for personal use, or for employers under 250 staff and under $10M revenue. Don't start it until stage 3 step 4, so the VM is built with `.wslconfig` already in place |
| Claude Desktop | [claude.ai/download](https://claude.ai/download) | |
| Antigravity 2.0 | [antigravity.google/download](https://antigravity.google/download) | |
| Linear | [linear.app/download](https://linear.app/download) | |
| Gemini | [gemini.google/desktop](https://gemini.google/desktop) | It uses Alt+Space to open over any window. Keep its autostart off unless you use that shortcut daily |
| Zed Preview | [zed.dev/download/preview](https://zed.dev/download/preview) | Downloads updates in the background and applies them on restart |
| Figma Beta | [figma.com/downloads](https://www.figma.com/downloads/) | The *Beta* desktop app |
| pen.dev (formerly Pencil) | [pen.dev/downloads](https://www.pen.dev/downloads) | |
| Vesktop | [vesktop.dev](https://vesktop.dev/) | |
| Telegram Desktop | [desktop.telegram.org](https://desktop.telegram.org/) | The installer version updates itself. Keep its autostart off |
| OBS Studio | [obsproject.com](https://obsproject.com/) | Desktop encoder and recording path: DESKTOP.md stage 5 |

### Small CLI tools, from winget

The shell tools the PowerShell profile wraps. These are the one group worth taking from winget
rather than a download: they are single executables that release often, winget shims them into
`%LOCALAPPDATA%\Microsoft\WinGet\Links` (already on PATH, so nothing to configure) and
`winget upgrade --all` then keeps all six current in one command.

```powershell
winget install --exact Starship.Starship sharkdp.bat eza-community.eza sharkdp.fd BurntSushi.ripgrep.MSVC junegunn.fzf
```

`winget install` takes several package queries at once; `--exact` stops a query matching some other
package by name. (`--id` is a single filter, not a repeatable flag — it does not work here.)

| Tool | winget id |
|---|---|
| starship | `Starship.Starship` |
| bat | `sharkdp.bat` |
| eza | `eza-community.eza` |
| fd | `sharkdp.fd` |
| ripgrep (`rg`) | `BurntSushi.ripgrep.MSVC` |
| fzf | `junegunn.fzf` |

The PowerShell profile checks for each one with `Get-Command` before using it, so installing them
after `install.ps1` is fine — the aliases and completions appear in the next shell.

### Agent CLIs

These are the vendors' own installers, run in PowerShell. Download a script and read it first if
you'd rather not pipe it.

| Tool | Command | Updates |
|---|---|---|
| Claude Code | `irm https://claude.ai/install.ps1 \| iex` | In the background, by itself. Installs to `%USERPROFILE%\.local\bin` and does **not** add it to PATH — `install.ps1` does that, so run it after (or re-run it) |
| Codex CLI | `powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 \| iex"` | Re-run the command. Installs to `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` |
| Antigravity CLI (`agy`) | `irm https://antigravity.google/cli/install.ps1 \| iex` | Re-run the command. Installs to `%LOCALAPPDATA%\agy\bin` |

### Updated by hand

| App | Source | Notes |
|---|---|---|
| CaskaydiaCove Nerd Font | [nerdfonts.com/font-downloads](https://www.nerdfonts.com/font-downloads) → *CascadiaCode* | Select every `.ttf`, then *Install for all users*. No winget package exists for it (winget has only `DEVCOM.JetBrainsMonoNerdFont`), so this stays manual. **Check the family name afterwards** — see below |
| Node.js LTS | [nodejs.org](https://nodejs.org/) | |
| pnpm | [pnpm.io/installation](https://pnpm.io/installation) | Use the PowerShell installer; update with `pnpm self-update` |

#### Three ways the Terminal config can be ignored

All three end with Terminal running but none of this repo's settings applied. Only the third one
says anything on screen. `scripts\doctor.ps1` checks all three.

**`profiles.list` must not be empty.** Terminal does **not** populate an empty list for you — it
loads the file, finds no profile, shows *"Failed to load settings … All profiles were hidden in your
settings"* and reverts to its built-in defaults. So `settings.json` lists three profiles with fixed,
machine-independent GUIDs (PowerShell 7 and the two inbox ones); Terminal adds what it generates
itself — Git Bash, WSL distros, Visual Studio — on top of them.

**The font family was renamed.** Nerd Fonts v3.4 shortened it from `CaskaydiaCove Nerd Font` to
**`CaskaydiaCove NF`** (plus `NFM` mono and `NFP` proportional). A `face` naming a font that isn't
installed falls back to another font without complaint. The configs list both spellings, then
`Cascadia Mono`, so either release works. Confirm what you actually have:

```powershell
(New-Object System.Drawing.Text.InstalledFontCollection).Families | Where-Object Name -like 'Caskaydia*'
```

**`defaultProfile` must match a generated profile name.** Terminal generates the PowerShell 7
profile from whatever `pwsh.exe` it finds — including the Store's PowerShell Preview — and current
builds name it plain **`PowerShell`**. Older builds used `PowerShell Preview (msix)`. A name that
matches nothing is not an error: Terminal quietly opens **Windows PowerShell 5.1** instead, which
reads a different profile directory, so no starship, no `eza`/`bat` aliases and no `pgstart`. If a
new tab opens the wrong shell, read the name off *Settings → Startup → Default profile* and put it
in `config\shared\windows-terminal\settings.json`.

Terminal itself stays a flat Catppuccin Latte surface — no background image, no acrylic. The
desktop wallpaper is a separate thing, below.

### Microsoft 365 Apps for enterprise (Word, Excel, PowerPoint)

The normal Microsoft 365 installer installs every app, including OneNote, OneDrive and Outlook. The
**Office Deployment Tool** installs only the apps you choose, straight from Microsoft's servers:

1. Download it from the
   [Microsoft Download Center (id 49117)](https://www.microsoft.com/download/details.aspx?id=49117)
   and extract it.
2. In an elevated terminal, from the extracted folder:

   ```powershell
   .\setup.exe /configure <repo>\config\shared\office\configuration.xml
   ```

   That installs Word, Excel and PowerPoint only: 64-bit, Current Channel, updating itself in the
   background.
3. Open Word and sign in with the work or school account that holds the Microsoft 365 Apps licence.

To change the selection later, edit the `ExcludeApp` lines and run the same command again. As long as
the language matches what's installed, the new list replaces the old one. If you'd rather click
through it, [config.office.com](https://config.office.com/deploymentsettings) builds the same kind of
file in a browser.

### PostgreSQL (for nopCommerce)

nopCommerce supports PostgreSQL 9.5 or later (since 4.40), so use the current release. This is a
**native** install, not a container — it is the one database that has to survive `docker` being
stopped.

**Part A — install it now (stage 2).**

1. Download the installer from [postgresql.org/download/windows](https://www.postgresql.org/download/windows/)
   (EDB's installer). Not winget: the winget package takes the defaults, and the two choices that
   matter here — which components, and where the data lives — are only offered by this installer.
2. **Components:** tick *PostgreSQL Server* and *Command Line Tools*. Untick *pgAdmin 4* and *Stack
   Builder*. Queries and browsing go through the VS Code PostgreSQL extension, `ms-ossdata.vscode-pgsql`.
3. **Data Directory:** `D:\PostgreSQL\18\Data`, on the Dev Drive. (The installer offers
   `C:\Program Files\PostgreSQL\18\data` — change it. Substitute your major version for `18` here
   and in every command below.)
4. **Password.** The installer asks for a password for the `postgres` superuser. Write it down: every
   `-U postgres` command below prompts for it, and there is no way to recover it later.
5. **Port.** Accept 5432 in the installer, then change it to **5434** in Part B. The default locale is
   fine. Let it finish, then come back after stage 3 — `tune.ps1` has to set the service to Manual
   first.

   Why 5434: the restored project stacks already publish Postgres containers on the host —
   `tryton-postgres-1` on **5432** and `structflow-postgres-1` on **5433**. Two servers cannot share
   a port, and the way this fails is genuinely nasty: the native service cannot bind, so it stays
   stopped, and `psql -U postgres` on `localhost:5432` then reaches the *container's* database
   instead. Same host, same port, different server — and the only symptom is
   `FATAL: password authentication failed`, which reads like your own password is wrong. Worse, had
   the passwords happened to match, `tuning.sql` would have run `ALTER SYSTEM` against the wrong
   server. Giving the native install its own port ends the whole class of problem.

**Part B — tune it (after stage 3).**

`tune.ps1` sets the service to **Manual**, so it costs nothing on the days you don't need it. That
also means it is *stopped* right now, and `psql` cannot connect to a stopped server — so start it
first. `pgstart` and `pgstop` come from the PowerShell profile and each cost one UAC prompt; on the
desktop, `gameprep` stops it for you.

**Type these into your own PowerShell session, from the repo root.** Unlike every other command in
this runbook they are not a script to hand to `pwsh -File`, for two reasons:

- `pgstart` and `pgstop` are **profile functions**. A shell started with `-NoProfile` does not have
  them (`pwsh -NoProfile -c 'Get-Command pgstart'` finds nothing).
- Wrapping the block in `pwsh -c "…"` breaks it. The shell you type into expands `$pg` and
  `$env:ProgramFiles` *before* the inner `pwsh` ever sees the string, so the inner shell is handed
  an already-empty variable and fails with ``The term '\psql.exe' is not recognized``.

**First, the port.** Edit `D:\PostgreSQL\18\Data\postgresql.conf`, change `port = 5432` to
`port = 5434`, and save. It is writable without elevation. This is the one setting that cannot go
through `tuning.sql`: `ALTER SYSTEM` needs a connection, and there is no connection until the server
can bind a port.

Then, with `-p 5434` on every call so you can never reach a container by accident:

```powershell
$pg = "$env:ProgramFiles\PostgreSQL\18\bin"
pgstart
& "$pg\psql.exe" -h localhost -p 5434 -U postgres -f .\config\shared\postgresql\tuning.sql
pgstop; pgstart
& "$pg\psql.exe" -h localhost -p 5434 -U postgres -c 'SHOW shared_buffers;'
```

If `pgstart` reports the service is still `Stopped`, read the warning it now prints — it names the
process holding the port. It used to swallow that failure entirely.

The last line should print `256MB`. If it still says `128MB`, the restart did not happen — run
`pgstop; pgstart` again and re-check.

`psql.exe` is not on PATH, which is why every call spells out `$pg`. Each of the two calls prompts
for the superuser password from step 4. To type it once instead, set `$env:PGPASSWORD` for the
session first — it lives only in that shell and dies with it. For a permanent answer, PostgreSQL
reads `%APPDATA%\postgresql\pgpass.conf`, one `hostname:port:database:username:password` line per
entry (`localhost:5432:*:postgres:<password>`); it is plain text, so treat it like any other
credential file.

`tuning.sql` uses `ALTER SYSTEM`, so it writes `postgresql.auto.conf` and never touches the
installer's `postgresql.conf`. To undo the whole thing: `ALTER SYSTEM RESET ALL;` then restart. The
file itself explains what each of the five settings is for and which ones need the restart.

### Desktop wallpaper

Nothing to do by hand — `install.ps1` sets it. `config\shared\wallpaper\wallpaper.png` is copied to
`%LOCALAPPDATA%\dotfiles\wallpaper.png` and Windows is pointed at that copy, with *Fill* (style 10),
which crops to the display's aspect ratio instead of stretching. The image is 3840×2160 — 16:9, like
both machines' panels — and it is a small centred mark on a flat field, so nothing of interest sits
near an edge that a crop could reach.

It is deliberately **not** left inside the repo checkout: Windows re-reads the file at every
sign-in, so a path in a folder you might move or delete would eventually leave you with a black
desktop. `install.ps1` writes the three `HKCU:\Control Panel\Desktop` values and then calls
`SystemParametersInfo`, which is what makes the change appear immediately rather than at the next
sign-in. `doctor.ps1` reports it if *Personalization → Background* later points somewhere else.

To change it, replace `config\shared\wallpaper\wallpaper.png` and re-run `install.ps1`. A different
file extension means editing the two `wallpaper.` lines in `config\shared\targets.ps1` as well, since
the copied file keeps its name.

### Mouse cursor: Cursor Concept 3 (free)

1. Download it from [jepricreations.com](https://jepricreations.com/products/cursor-concept-3-free)
   and extract it. It has light and dark variants.
2. In the variant's folder, right-click `install.inf` → **Install**. If there's no `install.inf`, use
   *Settings → Bluetooth & devices → Mouse → Additional mouse settings → Pointers* and browse to each
   `.cur`/`.ani` file.
3. Pick the new scheme on the *Pointers* tab.

The free pack comes in one size, 32 px. At the laptop's 125% scaling it can look a little small next
to Windows' own pointers; at the desktop's 100% it matches them. Larger sizes are in the paid version.
The files aren't in this repo, because redistribution isn't stated as allowed.

## 3. Apply

1. **Get the repo.** Clone it with `git clone`, for example into `D:\Code\dotfiles-windows`. A zip
   downloaded through a browser carries Mark-of-the-Web, and PowerShell refuses to run its scripts;
   `Get-ChildItem -Recurse | Unblock-File` fixes that.
2. **Run the scripts.** Do this after installing Microsoft 365 and PostgreSQL, so the OneDrive
   removal and the PostgreSQL service change both apply. In PowerShell Preview, from the repo root:

   ```powershell
   pwsh -File .\debloat\windows.ps1       # restore point, then Win11Debloat, silently (keeps Teams)
   pwsh -File .\tune.ps1
   pwsh -File .\install.ps1 -DevDrive D:  # may ask for your git name and email - see below
   Restart-Computer
   ```

   Each script prints `Profile: laptop` or `Profile: desktop` first. If that's wrong, pass
   `-Profile laptop` or `-Profile desktop` to every script (README, "How the two machines are told
   apart").

   **The git identity prompt only appears if `~\.gitconfig` is missing.** If GitHub Desktop has
   already signed in, it created that file and wrote your name and email into it, so `install.ps1`
   leaves it alone and never asks — that is correct, not a step that got skipped. Confirm with
   `git config --global --show-origin user.name`; `doctor.ps1` reports it as `git identity:`.

   `install.ps1` also adds two folders to your user PATH: `%LOCALAPPDATA%\Programs\bin` (a spare
   folder for one-off executables) and `%USERPROFILE%\.local\bin`, which is where Claude Code's
   installer puts `claude.exe` without putting it on PATH itself.
3. **Brave.** Run `pwsh -File .\debloat\brave.ps1`. In SlimBrave Neo, click **Import**, choose the
   *Performance Focused Preset.json* it put next to the script, then **Apply Settings**. Restart
   Brave and check `brave://policy`. The preset turns Leo off; switch it back on in the GUI before
   applying if you use it.
4. **Docker Desktop, first start.** Do this after `install.ps1`, so the VM is created with
   `.wslconfig` already in place.
   - *Settings → General*: turn **off** *Start Docker Desktop when you sign in*, and keep *Use the
     WSL 2 based engine* on.
   - *Resources*: turn on *Resource Saver*.
   - *Docker Engine* should show this repo's `daemon.json`.
5. **Startup apps.** Your call, not the repo's — `doctor.ps1` only *lists* what starts at sign-in, it
   no longer has an opinion about any of it. The ones usually worth turning off in
   *Settings → Apps → Startup* are Teams, WhatsApp, Telegram, ChatGPT, Claude, Gemini, Vesktop,
   GitHub Desktop, Figma, Docker Desktop and Brave. A few switch themselves back on, so turn it off
   inside the app too:
   - Teams: *Settings → General → Auto-start Teams*
   - WhatsApp: *Settings → General → Start WhatsApp at login*
   - Telegram: *Settings → Advanced → Launch Telegram when system starts*
   - On the desktop, also the game launchers (DESKTOP.md stage 5). Leave *AMD Software* on.
6. **Default apps.** Go to *Settings → Apps → Default apps → Brave* and choose *Set default*. Set the
   default terminal to Windows Terminal Preview (stage 2).
7. **Power.** [LAPTOP.md stage 3](LAPTOP.md#3-power) or [DESKTOP.md stage 6](DESKTOP.md#6-power-and-displays).
   Both keep the Balanced plan; neither uses Ultimate Performance.
8. **Check.** Run `pwsh -File .\scripts\doctor.ps1`, then run it again from an elevated terminal to
   get the compression, Dev Drive and Secure Boot checks, plus Memory Integrity and BitLocker on the
   desktop.

## 4. Restore

**On the desktop, skip `restore.ps1`:** it has no `backup.sh` folder, and nopCommerce starts from an
empty database. The notes after the script (hot reload, the nopCommerce database) still apply.

Before you start:
- Docker Desktop is running.
- `claude` has been started once to sign in.
- The stage 0 backup folder is reachable, on the external drive or copied to `D:\Backup`.
- **Each git remote has been signed into once**, so the clones don't stop halfway. See below.

### Git credentials, once per host

Git for Windows installs **Git Credential Manager** as the system-wide helper, and GCM keeps what it
gets in **Windows Credential Manager** — per Windows user, not per repo. Being signed in to the host
in Brave does not help: GCM does not read browser cookies.

What that means per host:

| Host | First time | After that |
|---|---|---|
| GitHub | GCM opens a browser window and you approve it. GitHub Desktop does this on its own, so if you signed into it there is usually nothing left to do | Silent |
| A self-hosted Gitea, such as `internal-git.siderian.cloud` | GCM has no browser sign-in for Gitea — it is not one of the four hosts it knows (GitHub, GitLab, Bitbucket, Azure DevOps). It shows a plain username/password box instead. Use a **Gitea access token** as the password (*Gitea → Settings → Applications → Generate New Token*, scope `read:repository`), not your account password | Silent |

So the sign-in is a one-time cost per host on a fresh Windows install, and the reason it did not
happen on the previous install is simply that Windows Credential Manager already held the entry.

Get it out of the way before the restore, so nothing blocks in the middle of it:

```powershell
git ls-remote https://internal-git.siderian.cloud/SocialHousingOSS/SocialHousingOSS.git   # prompts once
cmdkey /list | Select-String siderian                                                     # proves it stuck
```

Then the restore runs unattended.

Then one command, from this repo:

```powershell
pwsh -File .\migrate\restore.ps1 -Backup E:\windows-migration\<timestamp>
```

1. **Verify.** Every file is checked against `SHA256SUMS` before anything changes.
2. **Projects.** SocialHousingOSS and structflow are cloned into `D:\Code`, on the branch
   `backup.sh` recorded, and their local-only files go back in. Files that already exist are left
   alone. Git Credential Manager prompts here if you skipped the step above.
3. **Data.** Their Docker volumes and every Postgres database are restored. It asks once first,
   because this replaces what's in them. Each database server is started on its own and stopped
   again, since tryton's and structflow's both use port 5432.
4. **Claude.**
   - MCP servers are merged into `~\.claude.json`, and `npx` servers get the `cmd /c` wrapper Windows
     needs.
   - Skills go into `~\.agents\skills` and are linked into `~\.claude\skills`. Settings and rules are
     copied.
   - Transcripts and memory move to their `D:\Code` project names, so `/resume` lists them there.
   - Claude Desktop's Code-tab list is best effort: its format isn't documented. Any session also
     resumes with `claude --resume <id>`.

It's safe to re-run, and `-Skip` leaves steps out — any of `projects`, `data`, `claude`. Two useful
runs: `-Skip data,claude` does the clones only, so you can check them before anything existing is
replaced; and after opening Claude Desktop once and quitting it, `-Skip projects,data` does just the
Claude step. **Comma-separated, with no space after the comma** — `pwsh -File` splits its arguments
on whitespace, so `-Skip data, claude` would fail with "a positional parameter cannot be found".
Finally, bring each stack up with
`docker compose up -d` in its folder.

The script doesn't cover:
- **Plugins:** it prints their names for `/plugin install`.
- **Codex and Antigravity:** their Linux configs are in the backup's `agents\` folder.
- **claude.ai connectors:** they ask you to sign in again.

**nopCommerce database (native PostgreSQL).** Nothing is carried over for it, so it starts empty. To
load a dump made elsewhere, such as a `pg_dump -Fc` from a Postgres container, use the native tools.
Newer `pg_restore` versions read dumps made by older servers, so it restores as-is:

```powershell
pgstart
$pg = "$env:ProgramFiles\PostgreSQL\18\bin"
& "$pg\createdb.exe"   -h localhost -p 5434 -U postgres <database>
& "$pg\pg_restore.exe" -h localhost -p 5434 -U postgres -d <database> --no-owner --no-privileges <dump>
```

If roles are missing, apply the dump's `.globals.sql` with `psql` first. Point nopCommerce's
`appsettings.json` connection string at **`localhost:5434`** — not 5432, which belongs to the tryton
container (see the PostgreSQL section in stage 2).

**Hot reload in containers.** Services that bind-mount their source (`./app:/app/app` in
SocialHousingOSS) don't receive file-change events from files on the Windows side. Switch the
watcher to polling. For uvicorn/watchfiles, add `WATCHFILES_FORCE_POLLING=true` to the service's
environment.

**VS Code.** Nothing to do, and nothing in this repo. Sign in to **Settings Sync** with your GitHub
account (*gear → Backup and Sync Settings*) and it restores settings, keybindings, extensions,
snippets and UI state on its own. The one extension worth checking for afterwards is the PostgreSQL
one this runbook assumes, `ms-ossdata.vscode-pgsql`.

## 5. Measure

Each machine file has its own table: [LAPTOP.md stage 5](LAPTOP.md#5-measure) and
[DESKTOP.md stage 8](DESKTOP.md#8-measure). `.wslconfig` is shared, so its `memory=` has to suit the
heavier dev session of the two.
