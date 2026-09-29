# Dot-source this from the PowerShell profile. In a firstmate home, `claude`
# then starts through Git Bash with env.sh sourced, the same as a claude run
# from Git Bash: the overlay is on in every hook and tool shell, and claude.exe
# gets the MSYS pid that state/.lock records. A claude.exe started by
# PowerShell itself has no MSYS pid, so its session can never own the lock.
# Anywhere else `claude` is the plain executable.

function claude {
    $exe = (Get-Command claude -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $envSh = Join-Path $PWD.ProviderPath 'platform\windows\env.sh'
    if (-not ((Test-Path -LiteralPath $envSh) -and (Test-Path -LiteralPath (Join-Path $PWD.ProviderPath 'bin\fm-lock.sh')))) {
        & $exe @args
        return
    }
    $bash = $env:CLAUDE_CODE_GIT_BASH_PATH
    if (-not $bash) {
        $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
        $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        for ($dir = if ($git) { Split-Path $git.Source } else { '' }; $dir; $dir = Split-Path $dir) {
            if ((Test-Path -LiteralPath "$dir\bin\bash.exe") -and (Test-Path -LiteralPath "$dir\usr\bin")) { $bash = "$dir\bin\bash.exe"; break }
        }
    }
    $env:FM_WIN_LAUNCH_ENV = $envSh
    $env:FM_WIN_LAUNCH_CLAUDE = $exe
    try {
        & $bash -c 'e=$FM_WIN_LAUNCH_ENV c=$FM_WIN_LAUNCH_CLAUDE; unset FM_WIN_LAUNCH_ENV FM_WIN_LAUNCH_CLAUDE; . "$e" && exec "$c" "$@"' claude @args
    } finally {
        Remove-Item Env:FM_WIN_LAUNCH_ENV, Env:FM_WIN_LAUNCH_CLAUDE -ErrorAction SilentlyContinue
    }
}
