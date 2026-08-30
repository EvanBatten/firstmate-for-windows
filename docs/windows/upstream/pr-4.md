# PR-4: give the crewmate a working shell and a live cwd on Windows

Branch: `EvanBatten:pr-4-herdr-windows-pane` -> `kunchenguid/firstmate:main`.
Two commits on top of PR-3, 6 files, +1294 -34 against `main` (of which PR-3 contributes +956).
The pane work is the first; the second is a merge that brings PR-3's follow-up jq commit forward, so this branch stays a superset of PR-3 without a force-push.

**Stacked on PR-3.** Both change `bin/backends/herdr.sh` and `tests/fm-backend-herdr-windows.test.sh`, and this work reads as a diff against PR-3's, not against `main`.
Please merge PR-3 first; the diff to review here is `git diff pr-3-herdr-windows-cli..pr-4-herdr-windows-pane`, which is the pane commit plus the merge that carries PR-3's follow-up forward.

## What is wrong today

Two halves of one problem: a crewmate pane on Windows comes up in a shell that cannot run firstmate, and the field firstmate polls to learn where that pane is never moves.

**The shell.** herdr's `default_shell` on Windows is `pwsh`, and `tab create` has `--cwd`, `--env` and `--label` but no shell flag.
The two obvious ways to get to bash from there both fail:

- `exec bash -l` - `exec` is not a pwsh command.
- a bare `bash` - that is WSL's bash, not Git Bash, and it has no view of the repository's toolchain.

So the pane a crewmate is launched into cannot execute a single `bin/*.sh`.

**The cwd.** `fm_backend_herdr_current_path` reads `.foreground_cwd`, and on Windows that field is **always** `null`:

```console
$ herdr pane get <pane> --session <s> | jq -c '.result.pane | {cwd, foreground_cwd}'
{"cwd":"C:\\Users\\ebatt\\firstmate-gnhf","foreground_cwd":null}
```

`.cwd` is the field that is live - herdr feeds it from the shell emitting `ESC]9;9;<windows path>ESC\` at each prompt, which herdr injects into pwsh - and the adapter's comment explicitly warns not to read it, because on POSIX it is the frozen creation-time value.
Result: `bin/fm-spawn.sh`'s worktree wait never completes and every spawn times out.

## The fix

**One funnel for every task pane.**
`tab create --workspace W --cwd C --label L --no-focus` appeared inline at three sites - the plain spawn path, the presentation projection, and the projection's husk replacement.
All three produce a pane an agent is later launched into, so all three need the same treatment; they now go through `fm_backend_herdr_task_tab_create`, which on a POSIX host emits exactly that argument list and nothing else.

On MSYS the same function adds two `--env` flags and then sends the pane's first command:

```sh
herdr tab create --workspace W --cwd C --label L \
  --env "SHELL=C:\Program Files\Git\usr\bin\bash.exe" \
  --env 'PROMPT_COMMAND=printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"' \
  --no-focus
herdr pane run <pane> "& 'C:\Program Files\Git\usr\bin\bash.exe' --login"
```

The launch line is pwsh's call operator because the measured alternatives do not work.
The path is not a constant: it is `cygpath -w "$BASH"`, the Windows spelling of the very interpreter firstmate is running in, so a Git installed anywhere still resolves.
`cygpath -w` supplies the `.exe` suffix on its own.

**The environment is the carrier, not the keyboard.**
`PROMPT_COMMAND` is passed through `--env` rather than typed into the pane, and that is the load-bearing choice.
`treehouse get` does not `cd`; it spawns a **fresh** shell inside the worktree, and a variable typed into the outer bash would not be in that child's environment.
Arriving through `tab create --env` it is exported the whole way - herdr to pwsh to Git Bash to treehouse's subshell - so the emitter is still running in the exact shell whose cwd `fm-spawn.sh` is waiting to see.

Verified on this machine that nothing in Git Bash's login chain (`/etc/profile`, `/etc/profile.d/*.sh`, `~/.bash_profile`, `~/.bashrc`) assigns `PROMPT_COMMAND` or `cd`s away from the pane's `--cwd`, so `--login` neither clobbers the emitter nor loses the project directory.

`SHELL` is set for treehouse's benefit: it is a native Windows binary and cannot spawn a POSIX `/usr/bin/bash`.
Handing a bash session a Windows-spelled `SHELL` is only safe because nothing in `bin/` or `.agents/` reads `$SHELL` at all - checked, zero hits - so the only consumer is the one it is aimed at.

**The cwd fallback is gated on the pane host, not on emptiness.**
`fm_backend_herdr_current_path` now reads both fields from **one** `pane get` and falls back from `.foreground_cwd` to `.cwd`, folded back through `cygpath -u`.
The gate matters: on a POSIX host an empty `foreground_cwd` means the read failed, and `.cwd` there really is the frozen creation-time value the original comment warns about, so substituting it would hand `fm-spawn.sh`'s worktree poll and the relaunch check a path the pane may have left long ago.
On Windows `.cwd` is not a snapshot at all - it is the last path the pane's shell reported over OSC 9;9 - which is why the emitter above has to exist for the fallback to mean anything.
One `pane get` rather than two also means the two fields cannot disagree about a pane that is moving.

## Acceptance run: real herdr 0.8.2, isolated lab session

Provisioned and torn down with `bin/fm-herdr-lab.sh`; the default session was never touched and no server was stopped.
The probe called the shipped adapter functions directly.

```
win32_cli: yes
pane_bash: C:\Program Files\Git\usr\bin\bash.exe
tab=w1:t2 pane=w1:p2

-- pane transcript after task_tab_create --
> & 'C:\Program Files\Git\usr\bin\bash.exe' --login
ebatt@GeneralBerserk MINGW64 ~/firstmate-gnhf (...)
$

-- before treehouse get --
current_path=[/c/Users/ebatt/firstmate-gnhf]
{"cwd":"C:\\Users\\ebatt\\firstmate-gnhf","foreground_cwd":null}

-- treehouse get, then poll --
moved after 3s: /c/Users/ebatt/.treehouse/firstmate-gnhf-503d65/1/firstmate-gnhf
{"cwd":"C:\\Users\\ebatt\\.treehouse\\...\\firstmate-gnhf","foreground_cwd":null}

-- what that path actually is --
git rev-parse --show-toplevel   C:/Users/ebatt/.treehouse/firstmate-gnhf-503d65/1/firstmate-gnhf
git rev-parse --git-common-dir  C:/Users/ebatt/firstmate-gnhf/.git
```

The first pane command produced a Git Bash prompt, `treehouse get` ran in it, and three seconds later the pane's `.cwd` was the worktree and `fm_backend_herdr_current_path` reported it as a POSIX path a comparison can use.
`foreground_cwd` stayed `null` throughout, which confirms the measurement rather than working around a transient.
The last two lines are the proof that the emitter survived into treehouse's own subshell - the hop a typed `PROMPT_COMMAND` would not have survived.

## Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on both touched files | clean, ShellCheck 0.11.0, full extended analysis |
| `tests/fm-backend-herdr-windows.test.sh` (PR-3's 32 cases + 11 new) | 43 / 43 |
| `tests/fm-backend-herdr.test.sh`, POSIX identity of the refactored sites | all 16 `create_task` / `--no-focus` / husk-replacement cases and `current_path` pass |
| `tests/fm-backend-herdr-smoke.test.sh`, real herdr, isolated lab session | **16 / 16, exit 0** - was 14/15 before the port and 13 + one failure after PR-3 |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `tests/fm-documentation-audiences.test.sh` | 4 / 4 |

The smoke test is the number that matters most.
Its one long-standing failure was `current_path did not report the pane's cwd after cd /tmp, got ''` - this exact defect - and it is now green, which also means the run reaches the cases that were behind it.
The `/tmp` round trip is exact rather than lucky: `cygpath` reads the MSYS mount table, so `cygpath -u "$(cygpath -w /tmp)"` returns `/tmp`, not `/c/Users/ebatt/AppData/Local/Temp`.

`tests/fm-backend-herdr.test.sh`'s existing byte-exact assertions on the `tab create` line are what proves the POSIX call did not move, and they still pass.

## Documentation

`docs/herdr-backend.md` gains a "Windows (Git Bash / MSYS)" section covering the MSYS branches from PR-3 and PR-4 together, and both new documents are registered in `docs/documentation-audiences.json`.
That is what makes this pair self-contained for a reader who is not on Windows.

## Notes for the reviewer

The `--env` values are the interface here, and they are worth a hard look: `PROMPT_COMMAND` is a shell fragment that will be evaluated in the crewmate's shell at every prompt.
It contains no interpolation from any untrusted source - `cygpath -w "$PWD"` is evaluated by that shell, not by firstmate - but it is the one place this port writes code that another shell runs.

`fm_backend_herdr_win32_pane_bash` is PR-3's PE-magic probe plus the resolved bash path, so, exactly as in PR-3, every unit test's shell-script `herdr` fake keeps the plain branch even when the suite runs on Windows.
