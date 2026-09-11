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
   after stage 2.
4. The rest of the machine file: power, then measure.

Stage 0 is the only one that can't be redone.

## 0. Before the wipe (on CachyOS)

Everything below exists only on the disk you're about to erase. From the `dotfiles-linux` checkout,
the existing scripts cover the hard parts:

```bash
./scripts/db-backup.sh                    # every Postgres database, named volumes, project .env files
./scripts/agents-backup.sh export         # MCP servers, skills, rules: Claude Code, Codex, Antigravity
code-insiders --list-extensions > ~/Backup/vscode-extensions.txt
```

Then the things no script can do (`dotfiles-linux/docs/MIGRATION.md`, stages 2 and 3):

- [ ] Push every repo.
- [ ] In each repo, sweep for gitignored secrets beyond `.env`: `appsettings.Development.json`, dev
  certs, `*.pfx`, `docker-compose.override.yml`.
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
- [ ] Make a Windows 11 USB. Writing the ISO with `dd` does not make a bootable Windows stick. Use
  [Ventoy](https://www.ventoy.net/) and copy the ISO from
  [microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11)
  onto it.

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
| PowerShell Preview | Registers `pwsh.exe`. Terminal names its profile "PowerShell Preview (msix)" |
| Windows Terminal Preview | Then set *Settings → System → For developers → Terminal* to **Windows Terminal Preview** |
| Microsoft Teams | Kept by `debloat\windows.ps1` on purpose |
| WhatsApp Beta | A WebView2 wrapper around WhatsApp Web, so it isn't light. Keep its autostart off |
| ChatGPT | Published by OpenAI |
| Screenbox Media Player | |
| Wintoys | Use it for health checks, repairs and cleanup. **Not** its Ultimate Performance or Superfetch toggles, and not its service disabling (README, "Things not to fix") |

### Runtimes (Microsoft)

| Runtime | Source | Notes |
|---|---|---|
| Visual C++ v14 Redistributable | [x64](https://aka.ms/vc14/vc_redist.x64.exe) and [x86](https://aka.ms/vc14/vc_redist.x86.exe) permalinks from [Microsoft Learn](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) | Install **both**: the runtime must match each app's architecture, and plenty of apps are still 32-bit |
| DirectX End-User Runtime | [Microsoft Download Center, id 35](https://www.microsoft.com/download/details.aspx?id=35) | Adds the legacy D3DX9/10/11, XAudio 2.7 and XInput 1.3 libraries some older apps expect. It doesn't change the DirectX version |
| .NET SDK 9 and 10 | [dotnet.microsoft.com/download](https://dotnet.microsoft.com/download) | Patched through Microsoft Update (stage 1) |

### Official installers

Most of these update themselves from inside the app.

| App | Source | Notes |
|---|---|---|
| Git for Windows | [git-scm.com/downloads/win](https://git-scm.com/downloads/win) | Install **first**. Keep **Git Credential Manager**. Line endings: **Checkout as-is, commit as-is**. Claude Code uses its Git Bash for the Bash tool |
| GitHub Desktop | [desktop.github.com](https://desktop.github.com/) | Updates itself. Signs in on its own |
| VS Code Insiders | [code.visualstudio.com/insiders](https://code.visualstudio.com/insiders/) | Keep "Add to PATH" |
| Brave | [brave.com/download](https://brave.com/download/) | |
| Docker Desktop | [docs.docker.com/desktop/setup/install/windows-install](https://docs.docker.com/desktop/setup/install/windows-install/) | Use the WSL 2 backend. **Licence:** free only for personal use, or for employers under 250 staff and under $10M revenue. Don't start it until stage 3 step 4 |
| Claude Desktop | [claude.ai/download](https://claude.ai/download) | |
| Antigravity 2.0 | [antigravity.google/download](https://antigravity.google/download) | |
| Gemini | [gemini.google/desktop](https://gemini.google/desktop) | It uses Alt+Space to open over any window. Keep its autostart off unless you use that shortcut daily |
| Zed Preview | [zed.dev/download/preview](https://zed.dev/download/preview) | Downloads updates in the background and applies them on restart |
| Figma Beta | [figma.com/downloads](https://www.figma.com/downloads/) | The *Beta* desktop app |
| pen.dev (formerly Pencil) | [pen.dev/downloads](https://www.pen.dev/downloads) | |
| Vesktop | [vesktop.dev](https://vesktop.dev/) | |
| Telegram Desktop | [desktop.telegram.org](https://desktop.telegram.org/) | The installer version updates itself. Keep its autostart off |
| OBS Studio | [obsproject.com](https://obsproject.com/) | Desktop encoder and recording path: DESKTOP.md stage 5 |

### Command-line tools

These are the vendors' own installers, run in PowerShell. Download a script and read it first if
you'd rather not pipe it.

| Tool | Command | Updates |
|---|---|---|
| Claude Code | `irm https://claude.ai/install.ps1 \| iex` | In the background, by itself |
| Codex CLI | `powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 \| iex"` | Re-run the command. Installs to `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` |
| Antigravity CLI (`agy`) | `irm https://antigravity.google/cli/install.ps1 \| iex` | Re-run the command. Installs to `%LOCALAPPDATA%\agy\bin` |

### Updated by hand

| App | Source | Notes |
|---|---|---|
| CaskaydiaCove Nerd Font | [nerdfonts.com/font-downloads](https://www.nerdfonts.com/font-downloads) → *CascadiaCode* | Select every `.ttf`, then *Install for all users* |
| Starship | [github.com/starship/starship/releases](https://github.com/starship/starship/releases) | `starship-x86_64-pc-windows-msvc.msi` |
| bat, eza, fd, ripgrep, fzf | [bat](https://github.com/sharkdp/bat/releases) · [eza](https://github.com/eza-community/eza/releases) · [fd](https://github.com/sharkdp/fd/releases) · [ripgrep](https://github.com/BurntSushi/ripgrep/releases) · [fzf](https://github.com/junegunn/fzf/releases) | Download the Windows x64 zips and put the `.exe` files in `%LOCALAPPDATA%\Programs\bin`. `install.ps1` creates that folder and adds it to PATH |
| Node.js LTS | [nodejs.org](https://nodejs.org/) | |
| pnpm | [pnpm.io/installation](https://pnpm.io/installation) | Use the PowerShell installer; update with `pnpm self-update` |
| Python | [python.org/downloads/windows](https://www.python.org/downloads/windows/) | Tick "Add python.exe to PATH" |

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

nopCommerce supports PostgreSQL 9.5 or later (since 4.40), so use the current release.

1. Download the installer from [postgresql.org/download/windows](https://www.postgresql.org/download/windows/)
   (EDB's installer).
2. **Components:** tick *PostgreSQL Server* and *Command Line Tools*. Untick *pgAdmin 4* and *Stack
   Builder*. Queries and browsing go through the VS Code PostgreSQL extension, `ms-ossdata.vscode-pgsql`.
3. **Data Directory:** `D:\PostgreSQL\<version>\data`, on the Dev Drive.
4. After stage 3, `tune.ps1` sets the service to **Manual**. Start and stop it with `pgstart` and
   `pgstop`; each asks for admin once. On the desktop, `gameprep` stops it for you.
5. Apply the memory limits once, with the service running, then restart it:

   ```powershell
   & "$env:ProgramFiles\PostgreSQL\18\bin\psql.exe" -U postgres -f .\config\shared\postgresql\tuning.sql
   pgstop; pgstart
   ```

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
   pwsh -File .\install.ps1 -DevDrive D:  # asks once for your git name and email
   Restart-Computer
   ```

   Each script prints `Profile: laptop` or `Profile: desktop` first. If that's wrong, pass
   `-Profile laptop` or `-Profile desktop` to every script (README, "How the two machines are told
   apart").
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
5. **Startup apps.** In *Settings → Apps → Startup*, turn off Teams, WhatsApp, Telegram, ChatGPT,
   Claude, Gemini, Vesktop, GitHub Desktop, Figma, Docker Desktop and Brave. Also turn it off inside
   the apps that switch it back on by themselves:
   - Teams: *Settings → General → Auto-start Teams*
   - WhatsApp: *Settings → General → Start WhatsApp at login*
   - Telegram: *Settings → Advanced → Launch Telegram when system starts*
   - On the desktop, also the game launchers (DESKTOP.md stage 5). Leave *AMD Software* on.
6. **Default apps.** Go to *Settings → Apps → Default apps → Brave* and choose *Set default*. Set the
   default terminal to Windows Terminal Preview (stage 2).
7. **Power.** [LAPTOP.md stage 3](LAPTOP.md#3-power) or [DESKTOP.md stage 6](DESKTOP.md#6-power-and-displays).
   Both keep the Balanced plan; neither uses Ultimate Performance.
8. **Check.** Run `pwsh -File .\scripts\doctor.ps1`, then run it again from an elevated terminal to
   get the compression, Dev Drive and (on the desktop) Memory Integrity checks.

## 4. Restore

**Projects.** Clone into `D:\Code`. The first clone or push of a private repo opens Git Credential
Manager's sign-in. Put each project's `.env` files back from the `db-backup.sh` snapshot.

**nopCommerce database (native PostgreSQL).** Newer `pg_restore` versions read dumps made by older
servers, so the dump from the Linux container restores as-is:

```powershell
pgstart
$pg = "$env:ProgramFiles\PostgreSQL\18\bin"
& "$pg\createdb.exe"   -U postgres <database>
& "$pg\pg_restore.exe" -U postgres -d <database> --no-owner --no-privileges <snapshot>\<database>.dump
```

If roles are missing, apply the snapshot's globals file with `psql` first. Point nopCommerce's
`appsettings.json` connection string at `localhost:5432`.

**Container databases (other projects).** Start only the database service, copy the dump in, and
restore it:

```powershell
cd D:\Code\structflow
docker compose up -d <db-service>
docker cp <snapshot>\<database>.dump <container>:/tmp/db.dump
docker exec <container> pg_restore -U <user> -d <database> --clean --if-exists --no-owner --no-privileges /tmp/db.dump
```

Take `<user>` from the project's `.env`, and the container and database names from the snapshot's
`databases.tsv`.

**Hot reload in containers.** Services that bind-mount their source (`./app:/app/app` in
SocialHousingOSS) don't receive file-change events from files on the Windows side. Switch the
watcher to polling. For uvicorn/watchfiles, add `WATCHFILES_FORCE_POLLING=true` to the service's
environment.

**Agent config.** Claude Code on Windows reads `%USERPROFILE%\.claude.json` and
`%USERPROFILE%\.claude\`. Merge `mcpServers` from the export's `mcp-servers.json`, then copy the
skills in. Any stdio server whose command pointed at a Linux path needs a Windows path instead.

**VS Code extensions.** Install your saved list, plus the PostgreSQL extension:

```powershell
Get-Content .\vscode-extensions.txt | ForEach-Object { code-insiders --install-extension $_ }
code-insiders --install-extension ms-ossdata.vscode-pgsql
```

## 5. Measure

Each machine file has its own table: [LAPTOP.md stage 5](LAPTOP.md#5-measure) and
[DESKTOP.md stage 8](DESKTOP.md#8-measure). `.wslconfig` is shared, so its `memory=` has to suit the
heavier dev session of the two.
