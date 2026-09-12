#Requires -Version 7.2
<#
.SYNOPSIS
    Put a migrate/backup.sh folder back on Windows: the projects, their databases,
    and Claude Code.

.DESCRIPTION
    Run it after docs\SETUP.md stage 3: Git, Docker Desktop and Claude Code are
    installed, Docker Desktop is running, and `claude` has been started once to
    sign in. User-level; never needs admin.

      1. Verify    every file against SHA256SUMS, before anything is written
      2. Projects  git clone into -CodeRoot when missing, then the files git
                   doesn't carry (.env, docker-compose.override.yml, ...)
      3. Data      Docker volumes, then each Postgres service on its own, then
                   pg_restore for every database it held
      4. Claude    MCP servers and skills; transcripts and memory under their
                   Windows project names; Claude Desktop's Code-tab session list

    Safe to re-run: anything that already exists is left alone. The exception is
    step 3, which replaces volumes and databases, so it asks once first.

.PARAMETER Backup
    The timestamped folder migrate/backup.sh wrote, copied to this machine.

.PARAMETER CodeRoot
    Where the projects live on Windows. Default <Dev Drive>:\Code - D:\Code on
    the laptop, E:\Code on the desktop. The letter is the one install.ps1
    -DevDrive recorded, or else the only ReFS volume there is.

.PARAMETER Skip
    Steps to leave out: projects, data, claude. Comma-separated with no spaces,
    because `pwsh -File` splits arguments on whitespace: -Skip data,claude.

.PARAMETER Yes
    Don't ask before replacing volumes and databases.

.EXAMPLE
    pwsh -File .\migrate\restore.ps1 -Backup G:\windows-migration\20260911T120000Z

.EXAMPLE
    pwsh -File .\migrate\restore.ps1 -Backup G:\windows-migration\20260911T120000Z -Skip projects,data
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Backup,
    # No literal default: the Dev Drive is D: on the laptop and E: on the
    # desktop, so it is worked out below.
    [string]$CodeRoot,
    # NB: deliberately NOT [ValidateSet]. `pwsh -File` - the way every example
    # here runs this script - passes arguments as literal strings and never
    # parses PowerShell syntax, so `-Skip data,claude` arrives as the single
    # string "data,claude". ValidateSet compares that whole string against the
    # set, fails, and the documented invocation becomes impossible. Splitting
    # and checking below accepts it. Write the list with NO space after the
    # comma: `pwsh -File` splits its arguments on whitespace, so "data, claude"
    # would make "claude" a second, unbindable positional argument.
    # ArgumentCompletions still offers the three values when you Tab.
    [ArgumentCompletions('projects', 'data', 'claude')][string[]]$Skip = @(),
    [switch]$Yes
)

$steps = 'projects', 'data', 'claude'
$Skip  = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknown = @($Skip | Where-Object { $_ -notin $steps })
if ($unknown) { throw "Unknown -Skip step(s): $($unknown -join ', '). Choose from $($steps -join ', ')." }

$tar    = Join-Path $env:SystemRoot 'System32\tar.exe'   # bsdtar, part of Windows
$counts = @{ ok = 0; warn = 0 }
function Section([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }
function Ok([string]$Text)      { $counts.ok++;   Write-Host "  ok    $Text" -ForegroundColor Green }
function Warn([string]$Text)    { $counts.warn++; Write-Host "  warn  $Text" -ForegroundColor Yellow }
function Info([string]$Text)    { Write-Host "        $Text" }

$Backup   = (Resolve-Path -LiteralPath $Backup -ErrorAction Stop).Path
$manifest = Get-Content (Join-Path $Backup 'manifest.json') -Raw -ErrorAction Stop | ConvertFrom-Json

# The Dev Drive's letter differs per machine. install.ps1 -DevDrive already
# pointed the package caches at it, so its letter is trusted first - as long as
# that drive is still ReFS. Otherwise a machine with exactly one ReFS volume
# has only one candidate. Anything else is a guess, so ask instead.
if (-not $CodeRoot) {
    $refs   = @(Get-Volume -ErrorAction Ignore | Where-Object { $_.DriveLetter -and $_.FileSystemType -eq 'ReFS' } |
        ForEach-Object { "$($_.DriveLetter)".ToUpperInvariant() })
    $cache  = [Environment]::GetEnvironmentVariable('npm_config_cache', 'User')
    $letter = if ($cache -and $refs -contains "$($cache[0])".ToUpperInvariant()) { "$($cache[0])".ToUpperInvariant() }
              elseif ($refs.Count -eq 1) { $refs[0] }
    if (-not $letter) {
        throw "Can't tell which drive is the Dev Drive (ReFS volumes: $(if ($refs) { $refs -join ', ' } else { 'none' })). Pass it: -CodeRoot E:\Code"
    }
    $CodeRoot = "${letter}:\Code"
}
# Before anything is written: a -CodeRoot on a drive this machine doesn't have
# (D:\Code typed out of habit on the desktop) would otherwise fail once per
# project, halfway through.
$CodeRoot = $CodeRoot.TrimEnd('\')
$drive    = Split-Path -Qualifier $CodeRoot -ErrorAction Ignore
if (-not $drive -or -not (Test-Path "$drive\")) { throw "-CodeRoot $CodeRoot is not on a drive this machine has. Nothing was changed." }

# ---- Helpers ------------------------------------------------------------------
# Claude Code names a project's folder after its path, every character that
# isn't a letter or digit replaced by '-':
#   /home/me/Documents/Code/myapp  ->  -home-me-Documents-Code-myapp
#   E:\Code\myapp                  ->  E--Code-myapp
function Get-ProjectKey([string]$Path) { $Path -replace '[^A-Za-z0-9]', '-' }

# A Linux path under the old code root, as the same path under -CodeRoot. $null
# for anything else (~/dotfiles, scratch folders): those have no Windows home.
function ConvertFrom-LinuxPath([string]$Path) {
    $root = $manifest.codeRoot
    if ($Path -eq $root) { return $CodeRoot }
    if ($Path -and $Path.StartsWith("$root/")) {
        return Join-Path $CodeRoot $Path.Substring($root.Length + 1).Replace('/', '\')
    }
    $null
}

# Extract a .tar.gz into a new temporary folder and return that folder.
function Expand-Backup([string]$Archive) {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    # Linux symlinks inside can fail to extract; nothing here needs them.
    & $tar -xzf $Archive -C $dir 2>$null
    $dir
}

# Copy every file under $From into $To, keeping whatever is already there.
function Copy-Missing([string]$From, [string]$To) {
    $placed = 0; $kept = 0
    foreach ($file in Get-ChildItem -LiteralPath $From -Recurse -File -Force -ErrorAction Ignore) {
        $dest = Join-Path $To $file.FullName.Substring($From.Length).TrimStart('\')
        if (Test-Path -LiteralPath $dest) { $kept++; continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $dest
        $placed++
    }
    [pscustomobject]@{ Placed = $placed; Kept = $kept }
}

$projects = @(Get-Content (Join-Path $Backup 'projects\projects.tsv') -ErrorAction Stop |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object {
        # projects.tsv: name, remote, branch, commit. Name every column: the LAST
        # variable in a PowerShell multiple assignment collects everything left
        # over, so three names against four columns would silently make $branch
        # an array of @(branch, commit) - and splatting that into git clone puts
        # the commit on the command line as a second positional argument.
        # Commit is recorded by backup.sh but nothing here checks it out.
        $name, $remote, $branch, $commit = $_ -split "`t"
        [pscustomobject]@{ Name = $name; Remote = $remote; Branch = $branch; Commit = $commit; Dir = Join-Path $CodeRoot $name }
    })

# The project a recorded Linux directory belongs to, or $null.
function Get-ProjectOf([string]$LinuxDir) {
    $win = ConvertFrom-LinuxPath $LinuxDir
    if (-not $win) { return $null }
    $projects | Where-Object { $win -eq $_.Dir -or $win.StartsWith("$($_.Dir)\") } | Select-Object -First 1
}

# ---- 1. Verify ----------------------------------------------------------------
Section 'Verify the backup'
$sums = Join-Path $Backup 'SHA256SUMS'
if (-not (Test-Path $sums)) { throw "No SHA256SUMS in $Backup - point -Backup at the timestamped folder backup.sh wrote." }
$bad = 0; $n = 0
foreach ($line in Get-Content $sums) {
    if ($line -notmatch '^([0-9a-f]{64})\s+\*?\./(.+)$') { continue }
    $hash, $rel = $Matches[1], $Matches[2]
    $n++
    $file = Join-Path $Backup $rel.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $file)) { Warn "missing: $rel"; $bad++; continue }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $hash) { Warn "checksum mismatch: $rel"; $bad++ }
}
if ($bad) { throw "$bad of $n file(s) missing or damaged. Nothing was changed - copy the backup again." }
Ok "$n file(s) match SHA256SUMS (taken $($manifest.taken))"

# ---- 2. Projects --------------------------------------------------------------
if ('projects' -notin $Skip) {
    Section "Projects in $CodeRoot"
    $hasGit = Get-Command git -CommandType Application -ErrorAction Ignore
    foreach ($p in $projects) {
        if (Test-Path (Join-Path $p.Dir '.git')) {
            Ok "$($p.Name) is already cloned"
        } elseif (-not $hasGit) {
            Warn "$($p.Name): git is not installed (docs\SETUP.md, stage 2)"; continue
        } elseif (-not $p.Remote) {
            Warn "$($p.Name): the backup has no remote for it - clone it into $($p.Dir) yourself, then re-run"; continue
        } else {
            Info "cloning $($p.Remote) - Git Credential Manager may ask you to sign in"
            # A detached HEAD records an empty branch column, and '--' stops git
            # reading a remote that begins with a dash as an option.
            $cloneArgs = @('clone') +
                $(if (-not [string]::IsNullOrWhiteSpace($p.Branch)) { @('--branch', $p.Branch) }) +
                @('--', $p.Remote, $p.Dir)
            git @cloneArgs
            if ($LASTEXITCODE) { Warn "$($p.Name): git clone failed"; continue }
            Ok "$($p.Name) cloned into $($p.Dir)"
        }
        $archive = Join-Path $Backup "projects\$($p.Name).tar.gz"
        if (-not (Test-Path $archive)) { Info "$($p.Name) has no local-only files in the backup"; continue }
        $tmp = Expand-Backup $archive
        $r = Copy-Missing $tmp $p.Dir
        Remove-Item $tmp -Recurse -Force
        Ok "$($p.Name): $($r.Placed) local-only file(s) placed, $($r.Kept) already there"
    }
}

# ---- 3. Docker volumes and databases ------------------------------------------
function Restore-Data {
    $snap = Get-ChildItem (Join-Path $Backup 'db') -Directory -ErrorAction Ignore | Sort-Object Name | Select-Object -Last 1
    if (-not $snap) { Warn 'no db\ snapshot in the backup'; return }
    if (-not (Get-Command docker -CommandType Application -ErrorAction Ignore)) {
        Warn 'docker is not installed - install Docker Desktop, then re-run with -Skip projects,claude'; return
    }
    docker info *> $null
    if ($LASTEXITCODE) { Warn 'Docker Desktop is not running - start it, then re-run with -Skip projects,claude'; return }

    # Compose projects inside the projects being restored - one project can hold
    # several - read from db-backup.sh's manifest: "<compose project> TAB <dir>".
    $composeDirs = @{}
    $inList = $false
    foreach ($line in Get-Content (Join-Path $snap.FullName 'manifest.txt')) {
        if ($line -like 'compose projects*') { $inList = $true; continue }
        if (-not $inList) { continue }
        if (-not $line.Trim()) { break }
        $compose, $wd = $line.Trim() -split "`t"
        if ($wd -and (Get-ProjectOf $wd)) { $composeDirs[$compose] = ConvertFrom-LinuxPath $wd }
    }

    # Non-Postgres volumes are named <compose project>_<volume>.
    $volumes = @(Get-Content (Join-Path $snap.FullName 'volumes.tsv') -ErrorAction Ignore |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object {
            # volumes.tsv: volume, file, bytes, sha256 - all four named, for the
            # reason spelled out where projects.tsv is read.
            $vol, $file, $bytes, $sha = $_ -split "`t"
            $compose = $composeDirs.Keys | Where-Object { $vol.StartsWith("${_}_") } |
                Sort-Object Length -Descending | Select-Object -First 1
            if ($compose) {
                [pscustomobject]@{ Volume = $vol; File = Split-Path $file -Leaf; Compose = $compose; Name = $vol.Substring($compose.Length + 1) }
            }
        })
    # databases.tsv: project, service, container, image, db, user, file, bytes, sha256, workdir
    $databases = @(Get-Content (Join-Path $snap.FullName 'databases.tsv') |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        ForEach-Object {
            $f = $_ -split "`t"
            if (Get-ProjectOf $f[9]) {
                [pscustomobject]@{ Compose = $f[0]; Service = $f[1]; Db = $f[4]; User = $f[5]; File = $f[6]; Dir = ConvertFrom-LinuxPath $f[9] }
            }
        })
    if (-not ($volumes.Count + $databases.Count)) { Ok 'no volumes or databases for these projects in the snapshot'; return }

    Info "$($volumes.Count) volume(s): $($volumes.Volume -join ', ')"
    Info "$($databases.Count) database(s): $(($databases | ForEach-Object { "$($_.Compose)/$($_.Db)" }) -join ', ')"
    if (-not $Yes -and (Read-Host '  Replace these with the backup? Whatever they hold now is lost [y/N]') -notmatch '^[yY]') {
        Warn 'volumes and databases skipped'; return
    }

    $volumeDir = Join-Path $snap.FullName 'volumes'
    foreach ($v in $volumes) {
        $users = @(docker ps -q --filter "volume=$($v.Volume)")
        if ($users) { docker stop @users *> $null }
        # Labelled the way compose labels its own volumes, so `docker compose up`
        # adopts this one instead of complaining that something else created it.
        docker volume create --label "com.docker.compose.project=$($v.Compose)" --label "com.docker.compose.volume=$($v.Name)" $v.Volume *> $null
        # Emptied first: tar merges, and a stale file would pass for restored data.
        docker run --rm --mount "type=volume,src=$($v.Volume),dst=/data" --mount "type=bind,src=$volumeDir,dst=/backup,readonly" `
            alpine sh -c 'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; tar xzf /backup/$1 -C /data' _ $v.File *> $null
        if ($LASTEXITCODE) { Warn "volume $($v.Volume): extract failed" } else { Ok "volume $($v.Volume)" }
        if ($users) { docker start @users *> $null }
    }

    foreach ($group in $databases | Group-Object Compose, Service) {
        $first = $group.Group[0]
        $label = "$($first.Compose)/$($first.Service)"
        if (-not (Test-Path $first.Dir)) { Warn "${label}: $($first.Dir) is missing - run the projects step first"; continue }

        # Only the database service, not the stack: the app must not start writing
        # before its data is in.
        Push-Location $first.Dir
        try { docker compose up -d $first.Service *> $null } finally { Pop-Location }
        if ($LASTEXITCODE) { Warn "${label}: 'docker compose up -d $($first.Service)' failed in $($first.Dir)"; continue }
        $container = docker ps -q --filter "label=com.docker.compose.project=$($first.Compose)" --filter "label=com.docker.compose.service=$($first.Service)" |
            Select-Object -First 1
        if (-not $container) { Warn "${label}: compose started no container"; continue }

        # Asked over TCP on purpose: while the image initialises a fresh volume, its
        # temporary server listens on the unix socket only (see db-restore.sh).
        $ready = $false
        foreach ($i in 1..120) {
            docker exec $container pg_isready -h 127.0.0.1 -U $first.User -d postgres *> $null
            if (-not $LASTEXITCODE) { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { Warn "${label}: Postgres never became ready"; continue }
        $password = @(docker inspect $container --format '{{range .Config.Env}}{{println .}}{{end}}') -match '^POSTGRES_PASSWORD=' |
            Select-Object -First 1
        $pgEnv = "PGPASSWORD=$(if ($password) { $password.Substring(18) })"

        foreach ($row in $group.Group) {
            # A fresh volume only has POSTGRES_DB. A server that held more
            # databases than that needs the others created first.
            $existing = @(docker exec -e $pgEnv $container psql -U $row.User -d postgres -tAc 'select datname from pg_database')
            if ($existing -notcontains $row.Db) {
                docker exec -e $pgEnv $container createdb -U $row.User -O $row.User -T template0 $row.Db *> $null
                if ($LASTEXITCODE) { Warn "$label/$($row.Db): could not create the database"; continue }
            }
            docker cp (Join-Path $snap.FullName $row.File.Replace('/', '\')) "${container}:/tmp/restore.dump" *> $null
            $output = docker exec -e $pgEnv $container pg_restore -U $row.User -d $row.Db --clean --if-exists --no-owner --no-privileges /tmp/restore.dump 2>&1
            $rc = $LASTEXITCODE
            docker exec $container rm -f /tmp/restore.dump *> $null
            if ($rc -eq 0) {
                Ok "database $label/$($row.Db)"
            } elseif (($output | Out-String) -match 'errors ignored on restore') {
                Warn "database $label/$($row.Db) restored WITH ERRORS - read them before trusting it:"
                $output | Select-Object -Last 15 | ForEach-Object { Info "$_" }
            } else {
                Warn "database $label/$($row.Db) FAILED (exit $rc)"
                $output | Select-Object -Last 15 | ForEach-Object { Info "$_" }
            }
        }
        # Stopped again: two projects' Postgres services can publish the same
        # host port, so the next one couldn't start while this one runs.
        Push-Location $first.Dir
        try { docker compose stop $first.Service *> $null } finally { Pop-Location }
    }
}
if ('data' -notin $Skip) {
    Section 'Docker volumes and databases'
    Restore-Data
}

# ---- 4. Claude ----------------------------------------------------------------
function Restore-Claude {
    $claudeHome = Join-Path $HOME '.claude'
    $config     = Join-Path $HOME '.claude.json'
    $agents     = Join-Path $Backup 'agents'

    if (Get-Process -Name claude -ErrorAction Ignore) {
        Warn 'Claude is running and can overwrite ~\.claude.json. Quit Claude Code and Claude Desktop, then re-run with -Skip projects,data'
        return
    }

    # MCP servers: merged into ~\.claude.json; a server you already have wins.
    $exported = Join-Path $agents 'mcp-servers.json'
    if (-not (Test-Path $config)) {
        Warn '~\.claude.json does not exist yet - run `claude` once to sign in, then re-run with -Skip projects,data'
    } elseif (Test-Path $exported) {
        $cfg     = Get-Content $config -Raw | ConvertFrom-Json -AsHashtable
        $servers = (Get-Content $exported -Raw | ConvertFrom-Json -AsHashtable).user
        if (-not $cfg.Contains('mcpServers')) { $cfg['mcpServers'] = [ordered]@{} }
        $added = @(); $kept = @()
        foreach ($name in @($servers.Keys)) {
            $server = $servers[$name]
            if ($cfg.mcpServers.Contains($name)) { $kept += $name; continue }
            if (-not $server.Contains('url')) {
                if ("$($server.command)".StartsWith('/')) { Warn "MCP server $name skipped - its command is a Linux path ($($server.command))"; continue }
                # npx, npm, pnpm and yarn are .cmd shims on Windows, which Claude Code
                # can't start directly; its docs launch them through `cmd /c`.
                if ($server.command -in 'npx', 'npm', 'pnpm', 'yarn') {
                    $server['args'] = @('/c', $server.command) + @($server.args | Where-Object { $null -ne $_ })
                    $server['command'] = 'cmd'
                }
            }
            $cfg.mcpServers[$name] = $server
            $added += $name
        }
        if ($added) {
            Copy-Item $config "$config.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            ConvertTo-Json -InputObject $cfg -Depth 100 | Set-Content -Path $config -Encoding utf8NoBOM
            Ok "MCP servers added: $($added -join ', ')"
        }
        if ($kept) { Ok "MCP servers already configured, left alone: $($kept -join ', ')" }
    }

    # Skills: one store in ~\.agents\skills, as on Linux, and a directory junction
    # per skill in ~\.claude\skills. Junctions need neither admin nor Developer Mode.
    $store = Join-Path $HOME '.agents\skills'
    foreach ($archive in 'agents-skills.tar.gz', 'skills.tar.gz') {
        $path = Join-Path $agents $archive
        if (-not (Test-Path $path)) { continue }
        $tmp = Expand-Backup $path
        # agents-skills.tar.gz holds skills\<name>; skills.tar.gz holds <name> directly,
        # mostly as Linux links into the store - only real folders are added from it.
        $from = if ($archive -eq 'agents-skills.tar.gz') { Join-Path $tmp 'skills' } else { $tmp }
        foreach ($skill in Get-ChildItem -LiteralPath $from -Directory -ErrorAction Ignore | Where-Object { -not $_.LinkType }) {
            $dest = Join-Path $store $skill.Name
            if (Test-Path -LiteralPath $dest) { continue }
            New-Item -ItemType Directory -Force -Path $store | Out-Null
            Move-Item -LiteralPath $skill.FullName -Destination $dest
        }
        Remove-Item $tmp -Recurse -Force
    }
    $skillsDir = Join-Path $claudeHome 'skills'
    New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null
    $linked = 0; $present = 0
    foreach ($skill in Get-ChildItem -LiteralPath $store -Directory -ErrorAction Ignore) {
        $link = Join-Path $skillsDir $skill.Name
        if (Test-Path -LiteralPath $link) { $present++; continue }
        New-Item -ItemType Junction -Path $link -Target $skill.FullName | Out-Null
        $linked++
    }
    Ok "skills: $linked linked into ~\.claude\skills, $present already there"

    # Settings and rules. The plugin cache is a download, so only the names come back.
    $settings = Join-Path $agents 'config.tar.gz'
    if (Test-Path $settings) {
        $tmp = Expand-Backup $settings
        $installed = Join-Path $tmp 'plugins\installed_plugins.json'
        $plugins = if (Test-Path $installed) { @((Get-Content $installed -Raw | ConvertFrom-Json -AsHashtable).plugins.Keys) }
        Remove-Item (Join-Path $tmp 'plugins') -Recurse -Force -ErrorAction Ignore
        $r = Copy-Missing $tmp $claudeHome
        Remove-Item $tmp -Recurse -Force
        Ok "settings and rules: $($r.Placed) file(s) placed, $($r.Kept) already there"
        if ($plugins) { Info "Plugins to reinstall with /plugin install: $($plugins -join ', ')" }
    }

    # Sessions. Transcripts and auto-memory sit in a folder named after the project
    # path; renaming it to the Windows path's name is what makes /resume list them,
    # and memory load, in <CodeRoot>\<project>. Folders with no Windows equivalent keep
    # their names: `claude --resume <id>` finds a session from any folder.
    $sessions = Join-Path $Backup 'claude\claude-code.tar.gz'
    if (Test-Path $sessions) {
        $tmp = Expand-Backup $sessions
        $oldPrefix = Get-ProjectKey $manifest.codeRoot
        $newPrefix = Get-ProjectKey $CodeRoot
        $renamed = 0; $asIs = 0; $placed = 0
        foreach ($dir in Get-ChildItem (Join-Path $tmp 'projects') -Directory -ErrorAction Ignore) {
            $key = $dir.Name
            if ($key -eq $oldPrefix -or $key.StartsWith("$oldPrefix-")) { $key = $newPrefix + $key.Substring($oldPrefix.Length); $renamed++ }
            else { $asIs++ }
            $placed += (Copy-Missing $dir.FullName (Join-Path $claudeHome "projects\$key")).Placed
        }
        Ok "transcripts and memory: $placed file(s); $renamed project folder(s) renamed for $CodeRoot, $asIs kept as they were"
        foreach ($sub in 'plans', 'file-history') {
            $from = Join-Path $tmp $sub
            if (Test-Path $from) { Ok "${sub}: $((Copy-Missing $from (Join-Path $claudeHome $sub)).Placed) file(s) placed" }
        }

        # Prompt history (the Up arrow) is filtered by project path, so those move too.
        # Lines are compared after conversion, which keeps a re-run from duplicating them.
        $history = Join-Path $tmp 'history.jsonl'
        if (Test-Path $history) {
            $target = Join-Path $claudeHome 'history.jsonl'
            $seen = [Collections.Generic.HashSet[string]]::new()
            foreach ($line in Get-Content $target -ErrorAction Ignore) { [void]$seen.Add($line) }
            $new = @(foreach ($line in Get-Content $history) {
                if (-not $line) { continue }
                $entry = $line | ConvertFrom-Json -AsHashtable
                $win = ConvertFrom-LinuxPath $entry.project
                if ($win) { $entry['project'] = $win }
                $json = ConvertTo-Json -InputObject $entry -Depth 20 -Compress
                if ($seen.Add($json)) { $json }
            })
            if ($new) { Add-Content -Path $target -Value $new -Encoding utf8NoBOM }
            Ok "prompt history: $($new.Count) entr(ies) added"
        }
        Remove-Item $tmp -Recurse -Force
    }

    # Claude Desktop. Not a documented format, so this is best effort: the Code tab
    # keeps one JSON file per session under claude-code-sessions\<org>\<account>\,
    # with the folder it ran in (cwd, originCwd). Only sessions whose folder exists
    # under -CodeRoot are added. local-agent-mode-sessions stays in the backup only.
    $desktopArchive = Join-Path $Backup 'claude\claude-desktop.tar.gz'
    if (Test-Path $desktopArchive) {
        $desktopHome = @(
            Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction Ignore |
                ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' }
            Join-Path $env:APPDATA 'Claude'
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $desktopHome) {
            Warn 'Claude Desktop data folder not found - open Claude Desktop once, sign in, quit it, then re-run with -Skip projects,data'
            return
        }
        $tmp = Expand-Backup $desktopArchive
        $root = Join-Path $tmp 'claude-code-sessions'
        $added = 0; $skipped = 0
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.json' -ErrorAction Ignore) {
            $session = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            $cwd = ConvertFrom-LinuxPath $session.cwd
            $dest = Join-Path $desktopHome ('claude-code-sessions' + $file.FullName.Substring($root.Length))
            if (-not $cwd -or -not (Test-Path $cwd) -or (Test-Path -LiteralPath $dest)) { $skipped++; continue }
            $session['cwd'] = $cwd
            if ($session.originCwd) { $session['originCwd'] = (ConvertFrom-LinuxPath $session.originCwd) ?? $cwd }
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            ConvertTo-Json -InputObject $session -Depth 100 -Compress | Set-Content -LiteralPath $dest -Encoding utf8NoBOM
            $added++
        }
        Remove-Item $tmp -Recurse -Force
        Ok "Claude Desktop: $added Code-tab session(s) added, $skipped skipped (folder not under $CodeRoot, or already there)"
        Info 'Best effort. If one does not show up, its transcript still resumes with: claude --resume <session id>'
    }
}
if ('claude' -notin $Skip) {
    Section 'Claude Code and Claude Desktop'
    Restore-Claude
}

Write-Host ("`n{0} ok, {1} warnings" -f $counts.ok, $counts.warn)
Write-Host 'Next: bring each stack up with `docker compose up -d` in its folder. A stack that joins an external network needs the stack that creates it running first.'
