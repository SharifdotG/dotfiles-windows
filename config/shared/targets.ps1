# Where everything goes on BOTH machines. install.ps1 applies this and
# scripts\doctor.ps1 checks it, so the two can never disagree about a path or a
# value. Get-DotfilesConfig (lib\profile.ps1) reads it and adds whatever
# config\<laptop|desktop>\profile.ps1 lists for the machine it runs on.

$packages = Join-Path $env:LOCALAPPDATA 'Packages'
$terminal = @('Microsoft.WindowsTerminal_8wekyb3d8bbwe', 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe') |
    ForEach-Object { Join-Path $packages $_ }
$vscode   = Join-Path $env:APPDATA 'Code - Insiders\User'

@{
    # Source is repo-relative. OnlyIf, when present, is a folder that must already
    # exist - the Store package folder of each Windows Terminal (stable is built
    # in, Preview comes from the Store) - so a Terminal that isn't installed
    # doesn't get a settings file nothing would ever read.
    Files = @(
        @{ Source = 'config\shared\powershell\Microsoft.PowerShell_profile.ps1'; Target = $PROFILE.CurrentUserCurrentHost }
        foreach ($package in $terminal) {
            @{ Source = 'config\shared\windows-terminal\settings.json'; Target = Join-Path $package 'LocalState\settings.json'; OnlyIf = $package }
        }
        @{ Source = 'config\shared\vscode-insiders\settings.json';    Target = Join-Path $vscode 'settings.json' }
        @{ Source = 'config\shared\vscode-insiders\keybindings.json'; Target = Join-Path $vscode 'keybindings.json' }
        # Git's XDG global file. ~\.gitconfig is left to you, GitHub Desktop and
        # `git config --global` - see the header of config\shared\git\config.
        @{ Source = 'config\shared\git\config';             Target = Join-Path $HOME '.config\git\config' }
        @{ Source = 'config\shared\starship\starship.toml'; Target = Join-Path $HOME '.config\starship.toml' }
        @{ Source = 'config\shared\bat\config';             Target = Join-Path $env:APPDATA 'bat\config' }
        # Docker Desktop's documented location; Settings > Docker Engine edits it.
        @{ Source = 'config\shared\docker\daemon.json';     Target = Join-Path $HOME '.docker\daemon.json' }
        @{ Source = 'config\shared\wsl\.wslconfig';         Target = Join-Path $HOME '.wslconfig' }
    )

    # Persistent USER environment variables - IDEs, build tools and anything
    # launched from the Start menu inherit these, not only shells that ran the
    # profile. Carried over from the Linux zshrc.
    Env = [ordered]@{
        # Node's default heap on a 16 GB machine is ~4 GB per process, and Nx will
        # happily run one per core. A cap per process keeps a build from eating
        # the whole machine.
        NODE_OPTIONS                = '--max-old-space-size=3072'
        NX_DAEMON                   = 'true'
        # Server GC keeps one heap per logical core - 8 on the laptop's i5-8365U,
        # 12 on the desktop's Ryzen 5 3600. Workstation GC is the right trade on
        # a 16 GB machine running several .NET processes at once.
        DOTNET_gcServer             = '0'
        DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    }

    # Set only by `install.ps1 -DevDrive <letter>`. Value = folder under
    # <letter>:\packages. Package restores then run on ReFS with Defender in
    # performance mode instead of paying real-time scanning on C:.
    DevDriveCaches = [ordered]@{
        npm_config_cache = 'npm'
        NUGET_PACKAGES   = 'nuget'
        PIP_CACHE_DIR    = 'pip'
    }
}
