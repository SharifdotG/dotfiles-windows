# Desktop additions to the PowerShell profile. install.ps1 copies this to
# Documents\PowerShell\profile.d\machine.ps1 on the desktop only; the shared
# profile loads it last, so pgstop and mem are already defined.

# gameprep - hand the dev stack's memory back before starting a game. On 16 GB
# the Docker VM (capped at 4 GB) plus PostgreSQL is the difference between a
# game fitting in RAM and a game stuttering on the pagefile.
# Everything it stops comes back on demand: pgstart, and Docker Desktop from the
# Start menu or `docker desktop start`.
function gameprep {
    $pg = Get-Service -Name 'postgresql*' -ErrorAction Ignore | Select-Object -First 1
    if ($pg.Status -eq 'Running') {
        Write-Host 'Stopping PostgreSQL (one UAC prompt)'
        pgstop
    }

    if (Get-Process -Name 'Docker Desktop' -ErrorAction Ignore) {
        Write-Host 'Stopping Docker Desktop'
        # The Docker Desktop CLI plugin, generally available since 4.39. It
        # waits for the app to quit; if it is missing or fails, close the app.
        if (Get-Command docker -CommandType Application -ErrorAction Ignore) {
            docker desktop stop
        }
        if (Get-Process -Name 'Docker Desktop' -ErrorAction Ignore) {
            Stop-Process -Name 'Docker Desktop'
        }
    }

    # The VM (VmmemWSL in Task Manager) can outlive Docker Desktop for a while.
    # Nothing else runs in WSL here, so a shutdown loses nothing.
    Write-Host 'Shutting down WSL'
    wsl.exe --shutdown

    mem
}
