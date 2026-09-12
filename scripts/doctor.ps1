#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only health check: is the tuning actually in effect, and where is the RAM?

.DESCRIPTION
    Changes nothing. Run it normally, and once from an elevated terminal too -
    Get-MMAgent, the Dev Drive trust query and the Secure Boot checks need admin
    and are skipped otherwise.
    Exits 1 when any check fails.

    It checks live state rather than config files: on Linux a setting that every
    file agreed on was found overridden by something else at runtime, twice.

    Shared checks first; scripts\doctor\<laptop|desktop>.ps1 adds the machine's own.

.PARAMETER MachineProfile
    -Profile laptop or -Profile desktop. Normally omitted: lib\profile.ps1 reads
    the chassis type. The DOTFILES_PROFILE environment variable also overrides it.
#>
[CmdletBinding()]
param(
    # Not $Profile: it would shadow the built-in $PROFILE (lib\profile.ps1).
    [ValidateSet('laptop', 'desktop')]
    [Alias('Profile')]
    [string]$MachineProfile
)

$repo    = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\profile.ps1')
. (Join-Path $repo 'lib\json.ps1')
$machine = Get-DotfilesConfig -Repo $repo -Machine (Get-DotfilesProfile -Override $MachineProfile)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Profile: $($machine.Name)"

$counts = @{ ok = 0; warn = 0; fail = 0 }
function Section([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }
function Ok([string]$Text)      { $counts.ok++;   Write-Host "  ok    $Text" -ForegroundColor Green }
function Warn([string]$Text)    { $counts.warn++; Write-Host "  warn  $Text" -ForegroundColor Yellow }
function Fail([string]$Text)    { $counts.fail++; Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Info([string]$Text)    { Write-Host "        $Text" }
function GB($Bytes)             { '{0:N1} GB' -f ([double]$Bytes / 1GB) }

# One sample of every process, reused below. Working Set - Private is the closest
# Windows counterpart to the PSS the Linux doctor used: summing plain Working Set
# counts shared DLL pages once per process (on Linux, summing RSS once reported a
# browser at 8.3 GB that was really using 5.6 GB).
$procs = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process |
    Where-Object Name -NotIn '_Total', 'Idle')
function PrivateBytes([string]$Pattern) {
    ($procs | Where-Object { ($_.Name -replace '#\d+$') -match $Pattern } |
        Measure-Object -Property WorkingSetPrivate -Sum).Sum
}

# ---- Memory -----------------------------------------------------------------
Section 'Memory'
$sysmain = Get-Service -Name SysMain -ErrorAction SilentlyContinue
if ($sysmain -and $sysmain.Status -eq 'Running' -and $sysmain.StartType -eq 'Automatic') {
    Ok 'SysMain running and automatic (memory compression depends on it)'
} else {
    Fail "SysMain is $($sysmain.Status)/$($sysmain.StartType) - memory compression is off without it. Run tune.ps1 (and check Wintoys didn't touch it)"
}

if ($isAdmin) {
    $mm = Get-MMAgent
    if ($mm.MemoryCompression)         { Ok 'memory compression on' }     else { Fail 'memory compression off - run tune.ps1 and restart' }
    if ($mm.PageCombining)             { Ok 'page combining on' }         else { Warn 'page combining off - run tune.ps1' }
    if (-not $mm.ApplicationPreLaunch) { Ok 'application pre-launch off' } else { Warn 'application pre-launch on - run tune.ps1' }
} else {
    Warn 'memory compression not checked - Get-MMAgent needs an elevated terminal'
}

if ((Get-CimInstance -ClassName Win32_ComputerSystem).AutomaticManagedPagefile) {
    Ok 'pagefile system-managed'
} else {
    Fail 'pagefile is sized by hand - the commit limit may be too low. Run tune.ps1'
}

$mem  = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
$pct  = [math]::Round(100 * $mem.CommittedBytes / $mem.CommitLimit)
$line = "commit $(GB $mem.CommittedBytes) of $(GB $mem.CommitLimit) ($pct%), available RAM $('{0:N1} GB' -f ($mem.AvailableMBytes / 1024))"
if ($pct -ge 90) { Warn $line } else { Ok $line }

# ---- Config files -----------------------------------------------------------
Section 'Config files'
foreach ($file in $machine.Files) {
    if ($file.OnlyIf -and -not (Test-Path $file.OnlyIf)) { continue }
    $src = Join-Path $repo $file.Source
    $dst = $file.Target
    if (-not (Test-Path $dst)) {
        Fail "missing $dst - run install.ps1"
    } elseif ((Get-FileHash $dst).Hash -eq (Get-FileHash $src).Hash) {
        Ok $dst
    } elseif ($file.Compare -eq 'JsonSubset') {
        # The app rewrote the file. Only report the settings this repo actually
        # sets - reformatting, key order and anything the app added on its own
        # are not drift. See the header of lib\json.ps1.
        try {
            $drift = @(Compare-JsonSubset (ConvertFrom-Jsonc $src) (ConvertFrom-Jsonc $dst) -Ignore @($file.Ignore))
        } catch {
            Warn "$dst could not be parsed as JSON ($($_.Exception.Message)) - re-run install.ps1"
            continue
        }
        if (-not $drift) {
            Ok "$dst (reformatted by the app; every managed setting still applies)"
        } else {
            Warn "$dst - $($drift -join ', ') differ$(if ($drift.Count -eq 1) { 's' }) from $($file.Source). Changed in the app's UI? Copy it back to the repo, or re-run install.ps1"
        }
    } else {
        Warn "$dst differs from $($file.Source) - changed in the app's UI? Copy it back to the repo, or re-run install.ps1"
    }
}
if (-not ($machine.Files | Where-Object { $_.OnlyIf -and (Test-Path $_.OnlyIf) })) {
    Warn 'no Windows Terminal package found - Terminal Preview comes from the Microsoft Store'
}
# defaultProfile is the one Terminal setting that fails silently: a name matching
# no profile is not an error, Terminal just opens Windows PowerShell 5.1 instead -
# which reads a different profile directory, so nothing in this repo applies. Only
# the live file can be checked, because the profiles are generated by Terminal.
foreach ($file in $machine.Files | Where-Object { $_.Target -like '*WindowsTerminal*settings.json' }) {
    if (-not (Test-Path $file.Target)) { continue }
    try { $live = ConvertFrom-Jsonc $file.Target } catch { continue }
    $names = @($live.profiles.list | ForEach-Object { $_.name })
    $guids = @($live.profiles.list | ForEach-Object { $_.guid })
    # Terminal refuses to load a settings file with no usable profile - it reports
    # "All profiles were hidden in your settings" and falls back to its built-in
    # defaults, so nothing in the file applies. It does NOT fill an empty list in
    # for you, which is why config\shared\windows-terminal\settings.json ships one.
    $visible = @($live.profiles.list | Where-Object { -not $_.hidden })
    if (-not $visible) {
        Fail "$($file.Target) has no visible profile - Terminal will refuse to load it and fall back to its defaults. config\shared\windows-terminal\settings.json must list at least one; re-run install.ps1"
        continue
    }

    # This setting is excluded from the drift check above (config\shared\targets.ps1
    # says why), so this owns it. Two questions. Does the value resolve at all - if
    # not, Terminal falls back without a word and nothing in this repo applies. And
    # does it resolve to the profile the repo asked for?
    # Either setting may be written as a name or as a GUID, so resolve both to a
    # profile name before comparing them.
    function Resolve-ProfileName($Value) {
        if ($Value -in $guids) { return ($live.profiles.list | Where-Object guid -eq $Value).name }
        if ($Value -in $names) { return $Value }
    }
    $wanted   = Resolve-ProfileName (ConvertFrom-Jsonc (Join-Path $repo $file.Source)).defaultProfile
    $resolved = Resolve-ProfileName $live.defaultProfile
    if (-not $resolved) {
        Fail "Terminal's defaultProfile '$($live.defaultProfile)' matches no profile, so it silently opens Windows PowerShell 5.1 and none of this repo's shell config applies. Available: $($names -join ', '). Put one of those in config\shared\windows-terminal\settings.json"
    } elseif ($resolved -eq $wanted) {
        Ok "Terminal opens '$resolved' by default"
    } else {
        Warn "Terminal opens '$resolved' by default, not the '$wanted' this repo sets - changed in Settings > Startup? Re-run install.ps1, or put '$resolved' in config\shared\windows-terminal\settings.json"
    }
}
# The wallpaper file is checked with the others above; this is whether Windows is
# actually pointed at it. Personalization > Background silently rewrites these.
$paper   = $machine.Wallpaper
$desktop = Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue
if ($desktop.WallPaper -eq $paper.Path -and $desktop.WallpaperStyle -eq $paper.Style) {
    Ok "desktop wallpaper set from $($paper.Path)"
} elseif (-not $desktop.WallPaper) {
    Warn 'no desktop wallpaper set - run install.ps1'
} else {
    Warn "desktop wallpaper is '$($desktop.WallPaper)' (style $($desktop.WallpaperStyle)), not this repo's $($paper.Path) (style $($paper.Style)) - changed in Personalization? Re-run install.ps1"
}
if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
    $gitName = git config --global user.name
    if ($gitName) { Ok "git identity: $gitName" } else { Fail 'git has no user.name - run install.ps1' }
    if (-not (Test-Path (Join-Path $HOME '.gitconfig'))) {
        Warn '~\.gitconfig is missing, so `git config --global` writes into the managed ~\.config\git\config. Run install.ps1'
    }
}

# ---- Environment ------------------------------------------------------------
Section 'Environment'
foreach ($kv in $machine.Env.GetEnumerator()) {
    $value = [Environment]::GetEnvironmentVariable($kv.Key, 'User')
    if ($value -eq $kv.Value) { Ok "$($kv.Key)=$value" } else { Fail "$($kv.Key) is '$value', expected '$($kv.Value)' - run install.ps1" }
}
foreach ($name in $machine.DevDriveCaches.Keys) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) { Warn "$name not set - install.ps1 -DevDrive <letter> points it at a Dev Drive"; continue }
    $fs = (Get-Volume -DriveLetter $value[0] -ErrorAction SilentlyContinue).FileSystemType
    if ($fs -eq 'ReFS') { Ok "$name=$value (ReFS)" } else { Warn "$name=$value is on '$fs', not a Dev Drive" }
}
$cache = [Environment]::GetEnvironmentVariable('npm_config_cache', 'User')
if ($cache -and $isAdmin) {
    $trust = fsutil devdrv query "$($cache[0]):" 2>&1 | Out-String
    if ($trust -match 'not trusted|untrusted') { Fail "$($cache[0]): is not a trusted Dev Drive - Defender scans it in real time. fsutil devdrv trust $($cache[0]):" }
    elseif ($trust -match 'trusted')           { Ok "$($cache[0]): is a trusted Dev Drive (Defender performance mode)" }
    else                                       { Info ($trust.Trim()) }
}

# ---- Tools ------------------------------------------------------------------
Section 'Tools on PATH'
# PATH as it is stored, not as this process inherited it. A shell that was open
# before something was installed has a stale copy, and reporting "not found" for
# a tool that is installed and one new tab away sends you looking in the wrong
# place. gh is deliberately absent from the list: GitHub Desktop covers it here.
$storedPath = @('Machine', 'User') |
    ForEach-Object { [Environment]::GetEnvironmentVariable('PATH', $_) -split ';' } |
    Where-Object { $_ } |
    ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') }
$extensions = @($env:PATHEXT -split ';' | Where-Object { $_ })
foreach ($tool in 'git', 'starship', 'eza', 'bat', 'fd', 'rg', 'fzf', 'node', 'pnpm', 'dotnet', 'python', 'docker', 'code-insiders', 'claude', 'codex', 'agy') {
    $cmd = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { Ok "$tool  $($cmd.Source)"; continue }
    $stored = $storedPath | ForEach-Object { $dir = $_; $extensions | ForEach-Object { Join-Path $dir "$tool$_" } } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($stored) { Warn "$tool is installed ($stored) but this shell's PATH is stale - open a new terminal" }
    else         { Warn "$tool not found - see the app checklist in docs\SETUP.md" }
}
# Nerd Fonts v3.4 shortened the installed family from "CaskaydiaCove Nerd Font"
# to "CaskaydiaCove NF", so both spellings count - and the one that was found is
# printed, because it has to match what the Terminal config asks for.
# The registry value names carry a style and a type, e.g. "CaskaydiaCove NF
# SemiBold (TrueType)", hence the prefix match.
$fonts = foreach ($key in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts', 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts') {
    $item = Get-Item $key -ErrorAction SilentlyContinue
    if ($item) { $item.GetValueNames() | Where-Object { $_ -like 'CaskaydiaCove NF*' -or $_ -like 'CaskaydiaCove Nerd Font*' } }
}
if ($fonts) {
    $families = @($fonts -replace ' \(.*\)$' -replace '^(CaskaydiaCove (?:NFM|NFP|NF|Nerd Font(?: Mono| Propo)?)).*$', '$1' | Sort-Object -Unique)
    Ok "CaskaydiaCove installed: $($families -join ', ')"
} else {
    Warn 'no CaskaydiaCove Nerd Font installed - Terminal falls back silently (docs\SETUP.md)'
}

# ---- PostgreSQL -------------------------------------------------------------
Section 'PostgreSQL'
$pg = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'postgresql%'" | Select-Object -First 1
if (-not $pg) {
    Warn 'no PostgreSQL service installed - see docs\SETUP.md (nopCommerce)'
} else {
    if ($pg.StartMode -eq 'Manual') { Ok "$($pg.Name) starts manually (pgstart / pgstop) - currently $($pg.State)" }
    else                            { Warn "$($pg.Name) start mode is $($pg.StartMode) - it holds memory all day. Run tune.ps1" }
    # The service command line carries the data directory: pg_ctl ... -D "<dir>"
    if ($pg.PathName -match '-D\s+"([^"]+)"') {
        $dataDir = $Matches[1]
        $fs = (Get-Volume -DriveLetter $dataDir[0] -ErrorAction SilentlyContinue).FileSystemType
        if ($fs -eq 'ReFS') { Ok "data directory $dataDir is on the Dev Drive" }
        else                { Warn "data directory $dataDir is on $fs - Defender scans every database write in real time" }

        # Who owns the port this server wants? A Docker container publishing the
        # same port is the failure that costs the most time: the service cannot
        # bind, so it silently stays stopped, and psql then connects to the
        # CONTAINER's database instead - same host, same port, different server,
        # and a password prompt that looks like your own password is wrong.
        $conf = Join-Path $dataDir 'postgresql.conf'
        $portLine = if (Test-Path $conf) { Select-String -Path $conf -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1 }
        $port = if ($portLine) { [int]$portLine.Matches[0].Groups[1].Value } else { 5432 }
        $listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $owner = if ($listener) { (Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue).Name }
        if (-not $listener) {
            Ok "port $port is free for it$(if ($pg.State -ne 'Running') { ' (it is stopped)' })"
        } elseif ($pg.State -eq 'Running' -and $owner -eq 'postgres') {
            Ok "listening on port $port"
        } else {
            Fail "port $port is held by $owner (pid $($listener.OwningProcess)), not this service - it cannot start, and psql on localhost:$port reaches that other server instead. `docker ps` shows a container publishing $port; stop it, or change 'port' in $conf"
        }
    }
    if ($pg.State -eq 'Running') { Info "PostgreSQL is using $(GB (PrivateBytes '^postgres$')) right now" }
}

# ---- Debloat ----------------------------------------------------------------
Section 'Debloat'
# The Appx cmdlets are Windows PowerShell modules; asking powershell.exe once is
# more reliable from PowerShell 7 than importing them through the compat layer.
$appx = @(powershell.exe -NoProfile -Command 'Get-AppxPackage | ForEach-Object Name' 2>$null)
if ($appx.Count -eq 0) {
    Warn 'could not list installed apps'
} else {
    if ($appx -contains 'MSTeams') { Ok 'Teams installed - kept on purpose' } else { Warn 'Teams not installed (Microsoft Store)' }
    $removed = [ordered]@{
        'MicrosoftWindows.Client.WebExperience' = 'Widgets'
        'Microsoft.Copilot'                     = 'Copilot'
        'Microsoft.YourPhone'                   = 'Phone Link'
        'Microsoft.BingNews'                    = 'News'
        'Microsoft.GamingApp'                   = 'Xbox app'
        'Microsoft.OutlookForWindows'           = 'new Outlook'
    }
    foreach ($id in $removed.Keys) {
        if ($appx -contains $id) { Fail "$($removed[$id]) ($id) is installed - re-run debloat\windows.ps1 (feature updates bring some back)" }
        else                     { Ok "$($removed[$id]) removed" }
    }
}
# Microsoft 365 setup reinstalls OneDrive whatever debloat did, so its mere
# presence is not worth failing over every time Office updates. What actually
# hurts is a redirected known folder: Documents or Desktop moved inside OneDrive
# means $PROFILE, and everything install.ps1 wrote next to it, now lives in a
# syncing folder. That is the failure. An installed-but-inert OneDrive passes.
$oneDrive = @(
    (Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe')
    (Join-Path $env:ProgramFiles 'Microsoft OneDrive\OneDrive.exe')
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive\OneDrive.exe')
) | Where-Object { Test-Path $_ }
$shellFolders = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
$redirected = @('Personal', 'Desktop') | Where-Object {
    $path = (Get-ItemProperty -Path $shellFolders -Name $_ -ErrorAction SilentlyContinue).$_
    $path -and [Environment]::ExpandEnvironmentVariables($path) -like '*OneDrive*'
}
if ($redirected) {
    Fail "OneDrive has taken over $($redirected -join ' and ') - your PowerShell profile is inside a syncing folder. Move it back: Settings > Accounts > Windows backup > Manage folder backup"
} elseif (-not $oneDrive) {
    Ok 'OneDrive removed'
} else {
    # The same StartupApproved rule the sign-in section uses: odd first byte off.
    $state = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name OneDrive -ErrorAction SilentlyContinue).OneDrive
    $runs  = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name OneDrive -ErrorAction SilentlyContinue).OneDrive
    if ($runs -and -not ($state -is [byte[]] -and ($state[0] -band 1))) {
        Warn 'OneDrive is installed and starts at sign-in - Office setup adds it back. Turn it off in Settings > Apps > Startup, or re-run debloat\windows.ps1'
    } else {
        Ok 'OneDrive installed but inert - no folder redirected, not started at sign-in'
    }
}
$office = Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16'
if (Test-Path $office) {
    # Only Word, Excel and PowerPoint belong here (config\shared\office\configuration.xml).
    $unwanted = [ordered]@{
        'ONENOTE.EXE'  = 'OneNote'
        'OUTLOOK.EXE'  = 'Outlook'
        'MSACCESS.EXE' = 'Access'
        'MSPUB.EXE'    = 'Publisher'
        'lync.exe'     = 'Skype for Business'
    }
    foreach ($app in $unwanted.GetEnumerator()) {
        if (Test-Path (Join-Path $office $app.Key)) {
            Warn "$($app.Value) is installed - run the Office Deployment Tool with config\shared\office\configuration.xml"
        } else {
            Ok "$($app.Value) not installed"
        }
    }
}

# ---- Brave ------------------------------------------------------------------
Section 'Brave'
$policy = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
$bg  = Get-ItemPropertyValue -Path $policy -Name BackgroundModeEnabled -ErrorAction SilentlyContinue
$eff = Get-ItemPropertyValue -Path $policy -Name HighEfficiencyModeEnabled -ErrorAction SilentlyContinue
if ($bg -eq 0)  { Ok 'background mode off - Brave exits with its last window' } else { Fail 'background mode policy not set - run debloat\brave.ps1 and apply the preset' }
if ($eff -eq 1) { Ok 'Memory Saver on' }                                          else { Fail 'Memory Saver policy not set - run debloat\brave.ps1 and apply the preset' }
Info "Brave is using $(GB (PrivateBytes '^brave$')) right now"

# ---- Apps that start at sign-in ---------------------------------------------
Section 'Apps that start at sign-in'
# On Linux, two chat apps set to autostart measured ~700 MB - the single biggest
# item on that machine. Listed here so the Windows equivalent cannot creep back.
$startup = [System.Collections.Generic.List[string]]::new()
$runKeys = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' }
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)
foreach ($k in $runKeys) {
    $run = Get-Item $k.Run -ErrorAction SilentlyContinue
    if (-not $run) { continue }
    $approved = Get-Item $k.Approved -ErrorAction SilentlyContinue
    foreach ($name in $run.GetValueNames()) {
        # StartupApproved holds a binary blob per entry: an odd first byte means
        # disabled (Task Manager writes 03), even or no entry means enabled.
        $state = if ($approved) { $approved.GetValue($name) }
        if ($state -is [byte[]] -and ($state[0] -band 1)) { continue }
        $startup.Add($name)
    }
}
# Store apps (WhatsApp, Teams, ChatGPT...) register StartupTasks instead of Run entries.
# State: 0 or 1 disabled (1 = by you), 2 enabled, 3 disabled by policy, 4 enabled by policy.
$appData = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
foreach ($package in Get-ChildItem $appData -ErrorAction SilentlyContinue) {
    foreach ($task in Get-ChildItem $package.PSPath -ErrorAction SilentlyContinue) {
        if ($task.GetValue('State') -in 2, 4) { $startup.Add("$($package.PSChildName -replace '_.*$') ($($task.PSChildName))") }
    }
}
foreach ($link in Get-ChildItem ([Environment]::GetFolderPath('Startup')) -Filter *.lnk -ErrorAction SilentlyContinue) {
    $startup.Add($link.BaseName)
}
if ($startup.Count -eq 0) {
    Ok 'nothing starts at sign-in'
} else {
    # A list, not a verdict. Which of these is worth its memory is a judgement
    # call that changes week to week, and it is made in Settings > Apps > Startup,
    # not here. Only the total is a fact worth stating.
    Info "$($startup.Count) entr$(if ($startup.Count -eq 1) { 'y' } else { 'ies' }) - turn any of them off in Settings > Apps > Startup"
    foreach ($name in $startup | Sort-Object) { Info "  $name" }
}

# ---- Secure Boot ------------------------------------------------------------
Section 'Secure Boot'
if ($isAdmin) {
    # Windows PowerShell's SecureBoot module, asked through powershell.exe for the
    # same reason as the Appx query above. A BIOS flash can reset the key store to
    # its defaults and drop the 2023 certificate newer boot media is signed with.
    $secureBoot = @(powershell.exe -NoProfile -Command @'
try { if (Confirm-SecureBootUEFI) { 'on' } else { 'off' } } catch { 'unsupported' }
try { if ([Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI -Name db).Bytes) -match 'Windows UEFI CA 2023') { 'ca2023' } } catch { }
'@ 2>$null)
    if ($secureBoot -contains 'on') {
        Ok 'Secure Boot on'
        if ($secureBoot -contains 'ca2023') { Ok 'Secure Boot db holds the Windows UEFI CA 2023' }
        else { Warn 'Secure Boot db lacks the Windows UEFI CA 2023 - Windows Update adds it; boot media signed with it will not start until then' }
    } else {
        $state = if ($secureBoot -contains 'off') { 'off' } else { 'unsupported or unreadable' }
        Fail "Secure Boot is $state - BIOS (docs\$($machine.Name.ToUpper()).md, BIOS)"
    }
} else {
    Warn 'Secure Boot not checked - Confirm-SecureBootUEFI needs an elevated terminal'
}

# ---- This machine only ------------------------------------------------------
# Laptop: sleep states and power modes. Desktop: RAM speed, the HDD, displays,
# Memory Integrity, WSL, BitLocker and GPU tuning.
. (Join-Path $PSScriptRoot "doctor\$($machine.Name).ps1")

# ---- Graphics ---------------------------------------------------------------
Section 'Graphics'
foreach ($gpu in Get-CimInstance -ClassName Win32_VideoController) {
    # The Windows version of the llvmpipe check: no driver means software rendering
    # for the browser, VS Code and Terminal - all CPU on a 15 W part.
    if ($gpu.Name -match 'Basic Display') { Fail "$($gpu.Name) - no real driver. Windows Update > Advanced options > Optional updates" }
    else                                  { Ok $gpu.Name }
}

# ---- Where the RAM is -------------------------------------------------------
Section 'Where the RAM is (Working Set - Private)'
$groups = [ordered]@{
    'Brave'                         = '^brave$'
    'VS Code Insiders'              = '^Code - Insiders$'
    'Teams'                         = '^ms-teams$'
    'WhatsApp'                      = '^WhatsApp'
    'WebView2 (Teams, WhatsApp...)' = '^msedgewebview2$'
    'AI desktop apps'               = '^(claude|ChatGPT|Gemini|Antigravity)'
    'Office'                        = '^(WINWORD|EXCEL|POWERPNT|OfficeClickToRun)$'
    'Node and .NET'                 = '^(node|dotnet)$'
    'PostgreSQL'                    = '^postgres$'
    'Container VM'                  = '^vmmem'
    'Docker Desktop (host side)'    = '^(com\.docker\..*|Docker Desktop)$'
    'Terminal and shells'           = '^(WindowsTerminal|OpenConsole|pwsh|powershell)$'
    'Windows shell'                 = '^(explorer|dwm|StartMenuExperienceHost|SearchHost|ShellExperienceHost|TextInputHost|sihost|ctfmon|RuntimeBroker)$'
    'Windows services and Defender' = '^(svchost|MsMpEng|lsass|csrss|services|wininit|winlogon|SearchIndexer|WmiPrvSE|audiodg|fontdrvhost|spoolsv)$'
    'Compression store'             = '^(MemCompression|Memory Compression)$'
}
foreach ($g in $machine.MemoryGroups.GetEnumerator()) { $groups[$g.Key] = $g.Value }
$accounted = 0
$rows = foreach ($g in $groups.GetEnumerator()) {
    $bytes = [double](PrivateBytes $g.Value)
    $accounted += $bytes
    [pscustomobject]@{ Group = $g.Key; GB = [math]::Round($bytes / 1GB, 2) }
}
$total = [double]($procs | Measure-Object -Property WorkingSetPrivate -Sum).Sum
$rows = @($rows) + [pscustomobject]@{ Group = 'Everything else'; GB = [math]::Round(($total - $accounted) / 1GB, 2) }
$rows | Sort-Object GB -Descending | Format-Table -AutoSize | Out-String | Write-Host
Info "Record these in docs\$($machine.Name.ToUpper()).md (Measure) and size .wslconfig memory= from a real dev session."

Write-Host ("`n{0} ok, {1} warnings, {2} failures" -f $counts.ok, $counts.warn, $counts.fail)
if ($counts.fail -gt 0) { exit 1 }
