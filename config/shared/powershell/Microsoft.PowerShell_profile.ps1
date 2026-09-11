# PowerShell 7 profile - copied to $PROFILE by install.ps1. Edit the repo copy.
#
# Every Windows Terminal tab pays this file's startup cost, so: no modules beyond
# the PSReadLine that ships with PowerShell 7, and every external tool sits behind
# a Get-Command check. A tool that is not installed yet is skipped, never an error.

# ---- Line editing -------------------------------------------------------------
# zsh habits from the Linux setup: Up/Down search history for what is already
# typed (oh-my-zsh's default), Tab walks a completion menu, and predictions come
# from your own history rather than a plugin.
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -HistoryNoDuplicates
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab       -Function MenuComplete

# Catppuccin Latte - the same hexes as the Linux zsh-syntax-highlighting theme,
# turned into 24-bit escape sequences.
$fg = { param([string]$hex) $c = [Convert]::FromHexString($hex.TrimStart('#')); "`e[38;2;$($c[0]);$($c[1]);$($c[2])m" }
Set-PSReadLineOption -Colors @{
    Default                = & $fg '#4c4f69'   # text
    Command                = & $fg '#40a02b'   # green
    Keyword                = & $fg '#40a02b'
    Parameter              = & $fg '#fe640b'   # peach
    Number                 = & $fg '#fe640b'
    String                 = & $fg '#df8e1d'   # yellow
    Operator               = & $fg '#d20f39'   # red
    Variable               = & $fg '#8839ef'   # mauve
    Type                   = & $fg '#1e66f5'   # blue
    Member                 = & $fg '#4c4f69'
    Comment                = & $fg '#acb0be'   # surface2
    Error                  = & $fg '#e64553'   # maroon
    InlinePrediction       = & $fg '#9ca0b0'   # overlay0
    ListPrediction         = & $fg '#1e66f5'
    ListPredictionSelected = "`e[48;2;204;208;218m"   # surface0 background
}
Remove-Variable fg

# ---- Prompt -------------------------------------------------------------------
# starship.toml is the Linux file unchanged, at %USERPROFILE%\.config\starship.toml
# - starship's default path on Windows too.
if (Get-Command starship -CommandType Application -ErrorAction Ignore) {
    Invoke-Expression (&starship init powershell)
}

# ---- Listing and viewing files ------------------------------------------------
# PowerShell 7 ships `ls` and `cat` as aliases (Get-ChildItem, Get-Content), and an
# alias always wins over a function of the same name - so the alias has to go
# before the function can take over.
if (Get-Command eza -CommandType Application -ErrorAction Ignore) {
    Remove-Alias ls -Force -ErrorAction Ignore
    function ls { eza --icons --group-directories-first @args }
    function ll { eza -l -a --icons --git --group-directories-first @args }
    function la { eza -la --icons --git --group-directories-first @args }
    function lt { eza --tree --level=2 --git-ignore @args }
    # Linux had this as `lS`; PowerShell names are case-insensitive, so it would
    # collide with `ls`.
    function l1 { eza --oneline @args }
}
if (Get-Command bat -CommandType Application -ErrorAction Ignore) {
    Remove-Alias cat -Force -ErrorAction Ignore
    function cat { bat --paging=never @args }
}

# ---- Memory -------------------------------------------------------------------
# Linux had `free -h && zramctl`. The Windows equivalents: available RAM, the
# commit charge against its limit (RAM + pagefile - what allocations actually run
# out of), and the compression store that does zram's job.
function mem {
    $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $store = Get-Process -Name 'Memory Compression' -ErrorAction Ignore
    [pscustomobject]@{
        AvailableGB   = [math]::Round($m.AvailableMBytes / 1024, 1)
        CommittedGB   = [math]::Round($m.CommittedBytes / 1GB, 1)
        CommitLimitGB = [math]::Round($m.CommitLimit / 1GB, 1)
        CompressionGB = if ($store) { [math]::Round($store.WorkingSet64 / 1GB, 2) } else { 'n/a (run elevated)' }
    } | Format-List
}

# Top 12 by Working Set - Private, with multi-process apps (brave, msedgewebview2,
# Code - Insiders) summed. Private, because summing plain Working Set counts
# shared DLL pages once per process - on Linux, summing RSS once reported a
# browser at 8.3 GB that was really using 5.6 GB.
function memhogs {
    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
        Where-Object Name -NotIn '_Total', 'Idle' |
        Group-Object { $_.Name -replace '#\d+$' } |
        ForEach-Object {
            [pscustomobject]@{
                Name      = $_.Name
                Processes = $_.Count
                PrivateMB = [math]::Round(($_.Group | Measure-Object WorkingSetPrivate -Sum).Sum / 1MB)
            }
        } |
        Sort-Object PrivateMB -Descending |
        Select-Object -First 12 |
        Format-Table -AutoSize
}

# ---- Docker and Nx ------------------------------------------------------------
if (Get-Command docker -CommandType Application -ErrorAction Ignore) {
    function dps    { docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' @args }
    function dstats { docker stats --no-stream @args }
    # NB: never -a and never --volumes. --volumes deletes the Postgres, MinIO and
    # Keycloak data; -a deletes every image not used by a running container, which
    # on a dev machine is most of the ones you use.
    function dprune { docker system prune -f; docker builder prune -f }
}
if (Get-Command npx -CommandType Application -ErrorAction Ignore) {
    # For when the Nx daemon misbehaves or balloons.
    function nxr { npx nx reset @args }
}

# ---- PostgreSQL (native, for nopCommerce) -------------------------------------
# tune.ps1 sets the service to Manual, so it costs nothing on days you don't need
# it - the docker.socket idea from the Linux setup. Starting or stopping a service
# needs admin, hence one UAC prompt. The elevated step runs in Windows PowerShell,
# which is always installed and isn't a Store-packaged app.
# The service is looked up when you call these, not at profile load.
function Invoke-PgService([ValidateSet('Start', 'Stop')][string]$Action) {
    $service = Get-Service -Name 'postgresql*' -ErrorAction Ignore | Select-Object -First 1
    if (-not $service) { Write-Warning 'No PostgreSQL service is installed.'; return }
    Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-Command', "$Action-Service -Name '$($service.Name)'")
    Get-Service -Name $service.Name | Format-Table Name, Status, StartType -AutoSize
}
function pgstart  { Invoke-PgService -Action Start }
function pgstop   { Invoke-PgService -Action Stop }
function pgstatus { Get-Service -Name 'postgresql*' -ErrorAction Ignore | Format-Table Name, Status, StartType -AutoSize }

# ---- This machine only --------------------------------------------------------
# install.ps1 puts config\<profile>\powershell\machine.ps1 here when the machine's
# profile has one (the desktop's gameprep). Loaded last, so it can use everything
# above.
if (Test-Path "$PSScriptRoot\profile.d\machine.ps1") { . "$PSScriptRoot\profile.d\machine.ps1" }
