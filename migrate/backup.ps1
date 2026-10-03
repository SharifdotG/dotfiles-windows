#Requires -Version 7.2
<#
.SYNOPSIS
    Back up, from one Windows machine, what migrate\restore.ps1 puts back on the
    other: Claude Code's MCP servers and skills, and the named projects' databases.

.DESCRIPTION
    The Windows counterpart of migrate/backup.sh, for moving between the laptop
    and the desktop rather than off Linux. It writes the same folder layout, so
    restore.ps1 reads it unchanged:

      projects/  projects.tsv (remote, branch), and the compose files git doesn't
                 carry (.env, docker-compose.override.yml) that the database
                 services need to start
      db/        pg_dump -Fc of EVERY database on each Postgres service under the
                 named projects - one per database, not one per server
      agents/    ~\.claude.json's MCP servers (user and project scope), Claude
                 Desktop's MCP servers, ~\.agents\skills and the skills that live
                 only in ~\.claude\skills, settings and rules, Antigravity's config

    Left out on purpose: transcripts and sessions, ~\.claude\.credentials.json,
    and the projects' code - git carries that.

    Running Postgres containers are dumped in place. A stopped one is read through
    a throwaway container from the same image on the same volume, publishing no
    ports: two of these stacks claim host port 5432, so starting the real
    container would fail whenever the other is up.

    THE OUTPUT HOLDS SECRETS: .env files, MCP bearer tokens and API keys.

.PARAMETER Project
    Folders under -CodeRoot whose Postgres databases to back up. Comma-separated
    with no spaces under `pwsh -File`: -Project structflow,SocialHousingOSS.

.PARAMETER Out
    Parent folder. Each run creates a new timestamped folder inside it.

.PARAMETER Skip
    Steps to leave out: data, agents.

.EXAMPLE
    pwsh -File .\migrate\backup.ps1 -Project structflow,SocialHousingOSS
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Project,
    [string]$Out = (Join-Path $HOME 'Backup\windows-migration'),
    [string]$CodeRoot = 'D:\Code',
    # Not [ValidateSet], for the reason given in restore.ps1's param block.
    [ArgumentCompletions('data', 'agents')][string[]]$Skip = @()
)

$Project = @($Project | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Skip    = @($Skip | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknown = @($Skip | Where-Object { $_ -notin 'data', 'agents' })
if ($unknown) { throw "Unknown -Skip step(s): $($unknown -join ', '). Choose from data, agents." }

$tar    = Join-Path $env:SystemRoot 'System32\tar.exe'   # bsdtar, part of Windows
$counts = @{ ok = 0; warn = 0 }
function Section([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }
function Ok([string]$Text)      { $counts.ok++;   Write-Host "  ok    $Text" -ForegroundColor Green }
function Warn([string]$Text)    { $counts.warn++; Write-Host "  warn  $Text" -ForegroundColor Yellow }
function Info([string]$Text)    { Write-Host "        $Text" }
function Size([long]$Bytes)     { if ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) } }

# ---- 1. Preflight -------------------------------------------------------------
Section 'Preflight'
$CodeRoot = $CodeRoot.TrimEnd('\')
$dirs = @{}
foreach ($p in $Project) {
    $dir = Join-Path $CodeRoot $p
    if (-not (Test-Path (Join-Path $dir '.git'))) { throw "$dir is not a git checkout. Nothing was written." }
    $dirs[$p] = $dir
}
Ok "projects: $($Project -join ', ')"
if ('data' -notin $Skip) {
    docker info *> $null
    if ($LASTEXITCODE) { throw 'Docker Desktop is not running - the databases live there. Start it, or add -Skip data.' }
    Ok 'docker reachable'
}

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
$OUT   = Join-Path $Out $stamp
New-Item -ItemType Directory -Force -Path (Join-Path $OUT 'projects'), (Join-Path $OUT 'agents') | Out-Null
Ok "writing $OUT"

# The project a compose working directory belongs to, or $null.
function Get-ProjectOf([string]$WorkDir) {
    foreach ($p in $Project) {
        if ($WorkDir -eq $dirs[$p] -or $WorkDir.StartsWith("$($dirs[$p])\", [StringComparison]::OrdinalIgnoreCase)) { return $p }
    }
    $null
}

# ---- 2. Databases -------------------------------------------------------------
# Found first: the projects step needs to know which compose folders they run from.
$pg = @()
if ('data' -notin $Skip) {
    foreach ($id in docker ps -a --format '{{.ID}}') {
        $i = docker inspect $id | ConvertFrom-Json
        if ($i.Config.Image -notmatch '(^|/)postgres(:|$)') { continue }
        $labels = $i.Config.Labels
        $wd = $labels.'com.docker.compose.project.working_dir'
        if (-not $wd -or -not (Get-ProjectOf $wd)) { continue }
        $envMap = @{}
        foreach ($e in $i.Config.Env) { $k, $v = $e -split '=', 2; $envMap[$k] = $v }
        $mount = $i.Mounts | Where-Object { $_.Type -eq 'volume' -and $_.Destination -match '/postgresql/data|/pgdata' } | Select-Object -First 1
        $user  = $envMap.POSTGRES_USER ?? 'postgres'
        $pg += [pscustomobject]@{
            Id = $id; Name = $i.Name.TrimStart('/'); Image = $i.Config.Image; Running = $i.State.Running
            Compose = $labels.'com.docker.compose.project'; Service = $labels.'com.docker.compose.service'; WorkDir = $wd
            User = $user; Db = $envMap.POSTGRES_DB ?? $user; PgData = $envMap.PGDATA
            Volume = $mount.Name; Dest = $mount.Destination
        }
    }
}

# ---- 3. Projects --------------------------------------------------------------
Section 'Projects: where to clone them from, and the compose files git does not carry'
$tsv = @("# name`tremote`tbranch`tcommit")
foreach ($p in $Project) {
    $dir = $dirs[$p]
    $tsv += "$p`t$(git -C $dir remote get-url origin 2>$null)`t$(git -C $dir branch --show-current)`t$(git -C $dir rev-parse HEAD)"

    # Only what `docker compose up` needs to start the database services. The
    # rest of the working tree travels by git, so restore.ps1 never overwrites it.
    $files = @(foreach ($wd in $pg.WorkDir | Where-Object { (Get-ProjectOf $_) -eq $p } | Sort-Object -Unique) {
        foreach ($name in '.env', 'docker-compose.override.yml', 'docker-compose.override.yaml', 'compose.override.yml', 'compose.override.yaml') {
            $f = Join-Path $wd $name
            if (-not (Test-Path -LiteralPath $f)) { continue }
            $rel = $f.Substring($dir.Length + 1).Replace('\', '/')
            if (-not (git -C $dir ls-files -- $rel)) { $rel }
        }
    })
    if ($files) {
        & $tar -czf (Join-Path $OUT "projects\$p.tar.gz") -C $dir @files
        if ($LASTEXITCODE) { Warn "${p}: could not archive $($files -join ', ')" } else { Ok "${p}: $($files -join ', ')" }
    } else {
        Ok "${p}: nothing outside git that its databases need"
    }
}
Set-Content -Path (Join-Path $OUT 'projects\projects.tsv') -Value $tsv -Encoding utf8NoBOM

if ('data' -notin $Skip) {
    Section 'Databases (pg_dump -Fc, one per database)'
    $snap = Join-Path $OUT "db\$stamp"
    New-Item -ItemType Directory -Force -Path (Join-Path $snap 'pg') | Out-Null
    $rows = @("# project`tservice`tcontainer`timage`tdb`tuser`tfile`tbytes`tsha256`tworkdir")
    $failed = 0
    if (-not $pg) { Warn "no Postgres containers under $($Project -join ', ')" }

    foreach ($c in $pg) {
        $scratch = $null
        if ($c.Running) {
            $target = $c.Id
        } elseif (-not $c.Volume) {
            Warn "$($c.Name): stopped and has no named data volume - SKIPPED"; $failed++; continue
        } elseif (docker ps -q --filter "volume=$($c.Volume)") {
            Warn "$($c.Name): stopped, but $($c.Volume) is mounted by a running container - SKIPPED"; $failed++; continue
        } else {
            # No POSTGRES_PASSWORD on purpose: on an unexpectedly empty volume the
            # entrypoint then refuses to initialise, instead of handing back an
            # empty cluster that dumps "successfully".
            $runArgs = @('run', '-d', '--rm', '-v', "$($c.Volume):$($c.Dest)") +
                $(if ($c.PgData) { @('-e', "PGDATA=$($c.PgData)") }) + @($c.Image)
            $scratch = docker @runArgs 2>$null
            if ($LASTEXITCODE -or -not $scratch) { Warn "$($c.Name): could not open $($c.Volume) with $($c.Image) - SKIPPED"; $failed++; continue }
            $target = $scratch
            Info "$($c.Name) is stopped - reading $($c.Volume) through a throwaway $($c.Image)"
        }

        try {
            # Over TCP: while the image initialises, its temporary server listens on
            # the unix socket only, and a socket check would call that one ready.
            $ready = $false
            foreach ($n in 1..120) {
                docker exec $target pg_isready -h 127.0.0.1 -U $c.User *> $null
                if (-not $LASTEXITCODE) { $ready = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $ready) { Warn "$($c.Name): Postgres never became ready - SKIPPED"; $failed++; continue }

            # Every database the server holds - POSTGRES_DB is only the one the
            # entrypoint created (tryton's server holds three).
            $dbs = @(docker exec $target psql -U $c.User -d $c.Db -tAc 'select datname from pg_database where datallowconn and not datistemplate order by datname' |
                Where-Object { $_ })
            if (-not $dbs) { Warn "$($c.Name): could not list its databases - falling back to $($c.Db)"; $dbs = @($c.Db) }

            foreach ($d in $dbs) {
                if ($d -eq 'postgres') {
                    $tables = docker exec $target psql -U $c.User -d postgres -tAc "select count(*) from pg_class c join pg_namespace s on s.oid = c.relnamespace where c.relkind in ('r','p') and s.nspname not in ('pg_catalog','information_schema')"
                    if ("$tables".Trim() -in '', '0') { continue }   # the empty maintenance database
                }
                $base = ("$($c.Compose)__$d" -replace '[^A-Za-z0-9._-]', '-')
                # Dumped inside the container, so client and server versions always
                # match, then copied out: no binary data through a PowerShell pipe.
                $err = docker exec $target pg_dump -U $c.User -d $d -Fc -Z6 --no-owner --no-privileges -f /tmp/migrate.dump 2>&1
                if ($LASTEXITCODE) { Warn "$($c.Compose)/${d}: pg_dump failed"; $err | ForEach-Object { Info "$_" }; $failed++; continue }
                # pg_restore -l reads the archive's table of contents: the cheapest
                # proof the dump is complete and not a truncated fragment.
                docker exec $target pg_restore -l /tmp/migrate.dump *> $null
                if ($LASTEXITCODE) { Warn "$($c.Compose)/${d}: dump is not a readable archive - DISCARDED"; $failed++; continue }
                $file = Join-Path $snap "pg\$base.dump"
                docker cp "${target}:/tmp/migrate.dump" $file *> $null
                docker exec $target rm -f /tmp/migrate.dump *> $null
                if (-not (Test-Path $file)) { Warn "$($c.Compose)/${d}: could not copy the dump out"; $failed++; continue }

                $bytes = (Get-Item $file).Length
                $sha   = (Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
                $rows += ($c.Compose, $c.Service, $c.Name, $c.Image, $d, $c.User, "pg/$base.dump", $bytes, $sha, $c.WorkDir) -join "`t"
                Ok "$($c.Compose)/$d  $(Size $bytes)  ($($c.Image))"
            }
        } finally {
            if ($scratch) { docker rm -f $scratch *> $null }
        }
    }

    Set-Content -Path (Join-Path $snap 'databases.tsv') -Value $rows -Encoding utf8NoBOM
    # Only databases are asked for; restore.ps1 still expects the file.
    Set-Content -Path (Join-Path $snap 'volumes.tsv') -Value "# volume`tfile`tbytes`tsha256" -Encoding utf8NoBOM
    $composeLines = $pg | Sort-Object Compose -Unique | ForEach-Object { "  $($_.Compose)`t$($_.WorkDir)" }
    Set-Content -Path (Join-Path $snap 'manifest.txt') -Encoding utf8NoBOM -Value (@(
        "taken     $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ'))"
        "docker    $(docker --version)"
        "databases $($rows.Count - 1) dumped, $failed failed"
        ''
        'compose projects and where they lived:'
    ) + $composeLines + '')
    if ($failed) { Warn "$failed database(s) or server(s) were NOT backed up - read the warnings above" }
}

# ---- 4. MCP servers, skills, settings -----------------------------------------
if ('agents' -notin $Skip) {
    Section 'MCP servers, skills and settings'
    $agents = Join-Path $OUT 'agents'
    $claudeHome = Join-Path $HOME '.claude'

    # Same shape as agents-backup.sh's export: user scope, and each project's own.
    $cfg = Get-Content (Join-Path $HOME '.claude.json') -Raw | ConvertFrom-Json -AsHashtable
    $projectScope = [ordered]@{}
    foreach ($path in $cfg.projects.Keys) {
        $m = $cfg.projects[$path].mcpServers
        if ($m -and $m.Count) { $projectScope[$path] = $m }
    }
    $export = [ordered]@{
        exported = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        user     = $cfg.mcpServers ?? [ordered]@{}
        projects = $projectScope
    }
    ConvertTo-Json -InputObject $export -Depth 100 | Set-Content -Path (Join-Path $agents 'mcp-servers.json') -Encoding utf8NoBOM
    Ok "Claude Code MCP servers: $($export.user.Count) user-scope; project-scope in $($projectScope.Count) folder(s)"

    # Claude Desktop keeps its own list. The Store build virtualises %APPDATA% into
    # its package folder, so both copies are read; the package's wins on a clash.
    $desktop = [ordered]@{}
    $desktopHomes = @(
        Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction Ignore |
            ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude' }
        Join-Path $env:APPDATA 'Claude'
    )
    foreach ($h in $desktopHomes) {
        $f = Join-Path $h 'claude_desktop_config.json'
        if (-not (Test-Path $f)) { continue }
        $servers = (Get-Content $f -Raw | ConvertFrom-Json -AsHashtable).mcpServers
        foreach ($name in @($servers.Keys)) { if (-not $desktop.Contains($name)) { $desktop[$name] = $servers[$name] } }
    }
    if ($desktop.Count) {
        ConvertTo-Json -InputObject ([ordered]@{ mcpServers = $desktop }) -Depth 100 |
            Set-Content -Path (Join-Path $agents 'claude-desktop-mcp.json') -Encoding utf8NoBOM
        Ok "Claude Desktop MCP servers: $($desktop.Keys -join ', ')"
    }

    # The skill store, and the skills that live only in ~\.claude\skills (real
    # folders, not junctions into the store).
    $store = Join-Path $HOME '.agents'
    if (Test-Path (Join-Path $store 'skills')) {
        & $tar -czf (Join-Path $agents 'agents-skills.tar.gz') -C $store skills
        if ($LASTEXITCODE) { Warn 'could not archive ~\.agents\skills' }
        else { Ok "~\.agents\skills: $((Get-ChildItem (Join-Path $store 'skills') -Directory).Count) skill(s)" }
    }
    $own = @(Get-ChildItem (Join-Path $claudeHome 'skills') -Directory -ErrorAction Ignore | Where-Object { -not $_.LinkType } | ForEach-Object Name)
    if ($own) {
        & $tar -czf (Join-Path $agents 'skills.tar.gz') -C (Join-Path $claudeHome 'skills') @own
        if ($LASTEXITCODE) { Warn 'could not archive ~\.claude\skills' } else { Ok "~\.claude\skills only: $($own -join ', ')" }
    }

    $config = @('settings.json', 'settings.local.json', 'CLAUDE.md', 'keybindings.json', 'rules', 'agents', 'commands', 'output-styles') |
        Where-Object { Test-Path (Join-Path $claudeHome $_) }
    if ($config) {
        & $tar -czf (Join-Path $agents 'config.tar.gz') -C $claudeHome @config
        if ($LASTEXITCODE) { Warn 'could not archive the Claude settings' } else { Ok "settings and rules: $($config -join ', ')" }
    }

    foreach ($pair in @(@('mcp_config.json', 'antigravity-mcp_config.json'), @('config.json', 'antigravity-config.json'))) {
        $f = Join-Path $HOME ".gemini\config\$($pair[0])"
        if (Test-Path $f) { Copy-Item $f (Join-Path $agents $pair[1]); Ok "Antigravity $($pair[0])" }
    }
}

# ---- 5. Manifest and checksums ------------------------------------------------
Section 'Manifest and checksums'
[ordered]@{ taken = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); home = $HOME; codeRoot = $CodeRoot; projects = $Project } |
    ConvertTo-Json | Set-Content -Path (Join-Path $OUT 'manifest.json') -Encoding utf8NoBOM
# sha256sum's format, which restore.ps1 parses: "<hash>  ./<path>".
$sums = Get-ChildItem $OUT -Recurse -File | Where-Object Name -ne 'SHA256SUMS' |
    ForEach-Object { './' + $_.FullName.Substring($OUT.Length + 1).Replace('\', '/') } |
    Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture) |
    ForEach-Object { "$((Get-FileHash (Join-Path $OUT $_.Substring(2)) -Algorithm SHA256).Hash.ToLowerInvariant())  $_" }
Set-Content -Path (Join-Path $OUT 'SHA256SUMS') -Value $sums -Encoding utf8NoBOM
Ok "SHA256SUMS: $($sums.Count) file(s)"

$total = (Get-ChildItem $OUT -Recurse -File | Measure-Object Length -Sum).Sum
Write-Host ("`nDone: {0}  ({1})   {2} ok, {3} warnings" -f $OUT, (Size $total), $counts.ok, $counts.warn)
Write-Host '  - It holds secrets (.env files, MCP tokens). Copy it to the other machine, not into a repo.'
Write-Host '  - On the other machine (docs\SETUP.md, "Moving between the laptop and the desktop"):'
Write-Host "      pwsh -File .\migrate\restore.ps1 -Backup <where you copied it>\$stamp"
exit ([int]($counts.warn -gt 0))
