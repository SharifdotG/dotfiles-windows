#Requires -Version 7.0
<#
.SYNOPSIS
    Machine-wide memory and system settings that the debloat tools do not cover.

.DESCRIPTION
    Needs admin and relaunches itself elevated. Idempotent: each setting is read
    first and only written when it differs, and the live state is printed at the
    end - on Linux a config file said one thing while the kernel did another more
    than once, so the value in effect is what gets shown, not the value written.

    The shared settings come first, then tune\<laptop|desktop>.ps1.

.PARAMETER MachineProfile
    -Profile laptop or -Profile desktop. Normally omitted: lib\profile.ps1 reads
    the chassis type. The DOTFILES_PROFILE environment variable also overrides it.

.EXAMPLE
    pwsh -File .\tune.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Not $Profile: it would shadow the built-in $PROFILE (lib\profile.ps1).
    [ValidateSet('laptop', 'desktop')]
    [Alias('Profile')]
    [string]$MachineProfile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\profile.ps1')
$machine = Get-DotfilesProfile -Override $MachineProfile

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # -NoExit keeps the elevated window open so its output can be read. The
    # profile is resolved here and passed on: the elevated process gets a fresh
    # environment, so a DOTFILES_PROFILE set only in this session would be lost.
    $relaunch = @('-NoProfile', '-NoExit', '-File', "`"$PSCommandPath`"", '-Profile', $machine)
    if ($WhatIfPreference) { $relaunch += '-WhatIf' }
    Start-Process pwsh -Verb RunAs -ArgumentList $relaunch
    return
}
Write-Host "Profile: $machine"

function Write-Step([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }
function Write-Line([string]$Mark, [string]$Text) { Write-Host "  $Mark $Text" }

function Set-Dword {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [string]$Name, [int]$Value, [string]$Why)

    $current = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($current -eq $Value) {
        Write-Line '=' "$Name = $Value"
        return
    }
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set to $Value")) {
        # NB: New-Item -Force on a registry key that already exists RECREATES it,
        # deleting every value inside. Only create what is missing.
        if (-not (Test-Path $Path)) { New-Item -Path $Path | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord
        Write-Line '+' "$Name = $Value  ($Why)"
    }
}

# ---- Memory compression -----------------------------------------------------
# Windows' answer to zram: pages trimmed from working sets are compressed into
# the "Memory Compression" store before anything is written to the pagefile.
#
# NB: the store is run by the SysMain service. "Disable SysMain to save RAM"
# guides - and WinUtil's "Set Services to Manual" tweak, which includes it -
# switch compression off along with it.
Write-Step 'SysMain and memory compression'
if ((Get-Service -Name SysMain).StartType -ne 'Automatic') {
    if ($PSCmdlet.ShouldProcess('SysMain', 'Set startup type to Automatic')) {
        Set-Service -Name SysMain -StartupType Automatic
        Write-Line '+' 'SysMain startup type -> Automatic'
    }
} else {
    Write-Line '=' 'SysMain starts automatically'
}
if ((Get-Service -Name SysMain).Status -ne 'Running') {
    if ($PSCmdlet.ShouldProcess('SysMain', 'Start')) {
        Start-Service -Name SysMain
        Write-Line '+' 'SysMain started'
    }
} else {
    Write-Line '=' 'SysMain is running'
}

$mm = Get-MMAgent
if (-not ($mm.MemoryCompression -and $mm.PageCombining)) {
    if ($PSCmdlet.ShouldProcess('Memory manager', 'Enable memory compression and page combining')) {
        Enable-MMAgent -MemoryCompression -PageCombining
        Write-Line '+' 'memory compression and page combining enabled (after a restart)'
    }
} else {
    Write-Line '=' 'memory compression and page combining are on'
}
# Pre-launch starts Store apps in the background before you open them so they
# appear instantly - by holding memory for apps you may never open.
if ($mm.ApplicationPreLaunch) {
    if ($PSCmdlet.ShouldProcess('Memory manager', 'Disable application pre-launch')) {
        Disable-MMAgent -ApplicationPreLaunch
        Write-Line '+' 'application pre-launch disabled'
    }
} else {
    Write-Line '=' 'application pre-launch is off'
}

# ---- Pagefile ---------------------------------------------------------------
# The pagefile sets the COMMIT LIMIT (RAM + pagefile), not only where pages go.
# Browsers, Node and .NET reserve far more address space than they touch; with the
# pagefile off or too small, allocations fail while Task Manager still shows free
# RAM. System-managed lets Windows grow it under pressure.
Write-Step 'Pagefile'
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if (-not $cs.AutomaticManagedPagefile) {
    if ($PSCmdlet.ShouldProcess('Pagefile', 'Set to system-managed')) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
        Write-Line '+' 'pagefile -> system-managed (after a restart)'
    }
} else {
    Write-Line '=' 'pagefile is system-managed'
}

# ---- File system and crash dumps --------------------------------------------
Write-Step 'File system and crash dumps'
Set-Dword -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 `
    -Why 'node_modules paths pass 260 characters'
# An automatic memory dump can run to several GB after a crash - written to the
# system disk under exactly the conditions that caused the crash. A small dump is enough
# to name the faulting driver. Same idea as ProcessSizeMax in the Linux coredump cap.
Set-Dword -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Value 3 `
    -Why 'small memory dump'

# ---- PostgreSQL -------------------------------------------------------------
# The installer registers the service as Automatic, so it holds its shared buffers
# and a handful of processes all day - including the days nopCommerce stays shut.
# Manual is the docker.socket idea from the Linux setup: nothing runs until you
# ask for it, with `pgstart` / `pgstop` from the PowerShell profile.
Write-Step 'PostgreSQL'
$pg = Get-Service -Name 'postgresql*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $pg) {
    Write-Line '-' 'no PostgreSQL service yet - re-run tune.ps1 after installing it'
} elseif ($pg.StartType -ne 'Manual') {
    if ($PSCmdlet.ShouldProcess($pg.Name, 'Set startup type to Manual')) {
        Set-Service -Name $pg.Name -StartupType Manual
        Write-Line '+' "$($pg.Name) startup type -> Manual (start it with pgstart)"
    }
} else {
    Write-Line '=' "$($pg.Name) starts manually"
}

# ---- What is in effect now --------------------------------------------------
Write-Step 'In effect now'
Get-MMAgent | Format-List MemoryCompression, PageCombining, ApplicationPreLaunch
Get-Service -Name SysMain | Format-Table Name, Status, StartType -AutoSize

# ---- This machine only ------------------------------------------------------
. (Join-Path $PSScriptRoot "tune\$machine.ps1")

Write-Host 'Restart Windows for compression and pagefile changes to take effect.'
