# Round-2 evidence: run .no-mistakes.yaml's commands.lint the way no-mistakes
# does on Windows (cmd.exe /d /c <line>), from a DEFAULT Machine+User PATH with
# Git Bash's own variables removed, as when the daemon is started from
# PowerShell or Windows Terminal instead of from a Git Bash shell.
# `--list-files` is appended so fm-lint.sh prints the file set it would lint and
# exits before ShellCheck starts.
# usage: pwsh -NoProfile -File lint-gate-default-path.ps1 <worktree> <base-commit>
param([string]$Worktree, [string]$BaseCommit)
Set-Location $Worktree

$lineOf = {
  param([string]$yamlText)
  $yamlText | python -c "import sys, yaml; print(yaml.safe_load(sys.stdin.read())['commands']['lint'])"
}
$targetLine = & $lineOf (Get-Content -Raw .no-mistakes.yaml)
$prevLine = & $lineOf ((git show "${BaseCommit}:.no-mistakes.yaml") -join "`n")

$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($v in 'MSYSTEM', 'MSYSTEM_PREFIX', 'MINGW_PREFIX', 'MINGW_CHOST', 'SHELL', 'OSTYPE',
               'CHERE_INVOKING', 'EXEPATH', 'ORIGINAL_PATH', 'TERM', 'SHLVL', 'HOME', 'PWD', 'OLDPWD') {
  Remove-Item "Env:$v" -ErrorAction SilentlyContinue
}

function Invoke-Cmd([string]$line, [string]$save) {
  "> cmd.exe /d /c $line"
  $out = & cmd.exe /d /c $line 2>&1
  $rc = $LASTEXITCODE
  $lines = @($out | ForEach-Object { "$_" -replace "`0", '' } | Where-Object { $_ -ne '' })
  if ($save) { $lines | Set-Content -Encoding utf8NoBOM (Join-Path $PSScriptRoot $save) }
  if ($lines.Count -gt 6) {
    $lines[0..4]
    "... ($($lines.Count) lines total)"
  } else { $lines }
  "exit code: $rc"
  ""
}

"## environment: default Machine+User PATH, Git Bash variables removed"
"> where bash"
(& where.exe bash 2>&1) | ForEach-Object { "  $_" }
"> where git"
(& where.exe git 2>&1) | ForEach-Object { "  $_" }
"> where sh"
(& where.exe sh 2>&1) | ForEach-Object { "  $_" }
"> cmd.exe /d /c bash -c ""uname -sr"""
(& cmd.exe /d /c 'bash -c "uname -sr"' 2>&1) | ForEach-Object { "  $("$_" -replace "`0", '')" }
"> cmd.exe /d /c git -c alias.u=""!uname -sr"" u"
(& cmd.exe /d /c 'git -c alias.u="!uname -sr" u' 2>&1) | ForEach-Object { "  $_" }
""
"## previous spelling (3de6307): commands.lint = $prevLine"
Invoke-Cmd "$prevLine --list-files" 'lint-list-default-path-prev.txt'
"## target spelling (3922aac): commands.lint = $targetLine"
Invoke-Cmd "$targetLine --list-files" 'lint-list-default-path-target.txt'
"## target spelling passes arguments through to the script (an invalid --jobs is refused by fm-lint.sh itself)"
Invoke-Cmd ($targetLine -replace '--jobs 1', '--jobs 3')
"## target spelling from a subdirectory (cmd.exe cwd = tests\): git runs the alias from the repository toplevel"
Push-Location tests
Invoke-Cmd "$targetLine --list-files"
Pop-Location
