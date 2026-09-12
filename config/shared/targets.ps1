# Where everything goes on BOTH machines. install.ps1 applies this and
# scripts\doctor.ps1 checks it, so the two can never disagree about a path or a
# value. Get-DotfilesConfig (lib\profile.ps1) reads it and adds whatever
# config\<laptop|desktop>\profile.ps1 lists for the machine it runs on.

$packages = Join-Path $env:LOCALAPPDATA 'Packages'
$terminal = @('Microsoft.WindowsTerminal_8wekyb3d8bbwe', 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe') |
    ForEach-Object { Join-Path $packages $_ }
$wallpaper = Join-Path $env:LOCALAPPDATA 'dotfiles\wallpaper.png'

@{
    # Source is repo-relative. OnlyIf, when present, is a folder that must already
    # exist - the Store package folder of each Windows Terminal (stable is built
    # in, Preview comes from the Store) - so a Terminal that isn't installed
    # doesn't get a settings file nothing would ever read.
    #
    # Compare = 'JsonSubset' marks a file its own program rewrites: Terminal,
    # Terminal and Docker Desktop reformat theirs and drop the comments the moment
    # a setting is changed in their UI. install.ps1 still copies the whole file,
    # but doctor.ps1 checks only that the keys set here are still in force, so
    # cosmetic churn is not reported as drift (lib\json.ps1). Everything without
    # this field is compared by hash. Ignore lists dotted key paths to leave out.
    Files = @(
        @{ Source = 'config\shared\powershell\Microsoft.PowerShell_profile.ps1'; Target = $PROFILE.CurrentUserCurrentHost }
        foreach ($package in $terminal) {
            # Ignored: $schema and $help are editor hints, and Terminal Preview
            # swaps in its own -preview schema URL. defaultProfile is written here
            # as a readable profile NAME, but Terminal resolves it to that
            # profile's GUID and writes the GUID back - a plain string comparison
            # would call that drift forever. doctor.ps1 has a check of its own for
            # it, which resolves both forms to a name before comparing.
            @{ Source = 'config\shared\windows-terminal\settings.json'; Target = Join-Path $package 'LocalState\settings.json'; OnlyIf = $package
               Compare = 'JsonSubset'; Ignore = @('$schema', '$help', 'defaultProfile') }
        }
        # No VS Code here on purpose. Its own Settings Sync, signed in with a
        # GitHub account, already carries settings, keybindings and extensions
        # across machines - and it writes them back whenever it syncs, so a copy
        # in this repo would be a second owner fighting the first.
        # Git's XDG global file. ~\.gitconfig is left to you, GitHub Desktop and
        # `git config --global` - see the header of config\shared\git\config.
        @{ Source = 'config\shared\git\config';             Target = Join-Path $HOME '.config\git\config' }
        @{ Source = 'config\shared\starship\starship.toml'; Target = Join-Path $HOME '.config\starship.toml' }
        @{ Source = 'config\shared\bat\config';             Target = Join-Path $env:APPDATA 'bat\config' }
        # Docker Desktop's documented location; Settings > Docker Engine edits it,
        # and re-serialises the whole file when it does.
        @{ Source = 'config\shared\docker\daemon.json';     Target = Join-Path $HOME '.docker\daemon.json'; Compare = 'JsonSubset' }
        @{ Source = 'config\shared\wsl\.wslconfig';         Target = Join-Path $HOME '.wslconfig' }
        # The desktop wallpaper. Copying it is all this entry does; install.ps1
        # then points Windows at this path (see Wallpaper below). It has to live
        # somewhere permanent outside the repo, because Windows reads the file
        # again on every sign-in - a path inside a checkout you might move or
        # delete would leave you with a black desktop.
        @{ Source = 'config\shared\wallpaper\wallpaper.png'; Target = $wallpaper }
    )

    # Applied by install.ps1 once the file above is in place. Style 10 is Fill,
    # which crops to the aspect ratio rather than stretching - the image is
    # 3840x2160, so it fills both machines' displays without distortion.
    Wallpaper = @{ Path = $wallpaper; Style = '10'; Tile = '0' }

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
