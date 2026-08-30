# Windows measurement

Phase A's findings ledger is the table below; each Phase B slice appends its own section as it lands.

## Phase A findings ledger

Measured 2026-08-29 on Windows 11 26200 against upstream `f66be0f` (2026-08-28).
Toolchain: Git Bash 5.2.37 (MINGW64), herdr 0.8.2 stable (protocol 20), treehouse 2.3.0, no-mistakes 1.57.0, Claude Code 2.1.251 (native `claude.exe`), gh 2.89, jq 1.6, node 24, tasks-axi 0.2.5, quota-axi 0.1.33, shellcheck 0.11, actionlint 1.7.12.
Developer Mode ON; user env `MSYS=winsymlinks:nativestrict`.
Same shape as the upstream `windows-herdr-spike.yml` table so the two can be read side by side.
The plan that owns the fix list is [plan.html](plan.html) (findings ledger numbers below match it).
Rows 22-25 were added by Phase C rather than Phase A and live in the "Phase C" section below; the plan's ledger carries all of them.

| # | Subsystem | Result | Measured detail | Fix owner |
| --- | --- | --- | --- | --- |
| 1 | Line endings at checkout | **FAIL** without `.gitattributes` | `core.autocrlf=true` (system + global); a plain clone had 151/151 `bin/*.sh` with CRLF (`file` reports "with CRLF line terminators"). With `* text=auto eol=lf` committed and `core.autocrlf=false` in the clone: 0/151, and `bin/fm-harness.sh` runs. | PR-1 (`.gitattributes`, this branch) |
| 2 | Harness ancestry (`ps -o`) | **FAIL** | MSYS `ps` rejects `-o` ("unknown option"); a hook bash reports PPID 1. `Get-CimInstance Win32_Process` walked from `/proc/$$/winpid` recovered the full chain: bash.exe → bash.exe → claude.exe → pwsh.exe → treehouse.exe → pwsh.exe → herdr.exe. | PR-2 (`bin/fm-proc-lib.sh`) |
| 3 | `kill -0` on native PIDs | **FAIL** | `kill -0 <herdr.exe pid>` → "No such process"; `ps -W` lists it. MSYS pids (watcher, daemon) work. | PR-2 |
| 4 | Symlink lock (`ln -s`) | **PASS with env** | Default MSYS `ln -s` deep-copied the target; with `MSYS=winsymlinks:nativestrict` a real link was created and `readlink` resolved it. | dotfiles PR #3 (env var, applied) |
| 5 | herdr socket path shape | **FAIL** | `herdr status --json` reports `C:\Users\ebatt\AppData\Roaming\herdr\herdr.sock`; `fm_backend_herdr_canonical_socket_path` refuses anything not starting with `/`, so the launcher same-session proof refuses every spawn. | PR-3 |
| 6 | Crewmate pane shell | **FAIL** | herdr `default_shell = "pwsh"`; `tab create` has no shell/command flag. In a pwsh pane `exec bash -l` fails (`exec` is not a command) and bare `bash` resolves to WSL's bash. Git Bash must be launched as `& 'C:\Program Files\Git\usr\bin\bash.exe' --login`. | PR-4 |
| 7 | Native event push (python3 AF_UNIX) | **DEGRADED** | `python3 -c "import socket; hasattr(socket,'AF_UNIX')"` → False on Store Python 3.13.5 and Anaconda 3.12; the reader exits 2 and the watcher polls (designed fallback, same as the upstream spike). | accept; optional PR-5 (.NET reader) |
| 8 | Presentation workspace ordering | **DEGRADED** | `herdr-workspace-move.py` requires a `/`-prefixed socket path and returns 2; adapter warns and continues. | accept |
| 9 | Presentation lock namespace (mode 700) | **FAIL** | Every Git Bash mount is `noacl` (`mount`: `/`, `/tmp`, `/c`). `mkdir -m 700` creates a 755 directory and exits 1; the validity check fails; the adapter then prints "herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close" (3x in the smoke test). Teardown cannot close panes. | PR-3 |
| 10 | Stale git lock proof (`lsof`) | **DEGRADED** | No `lsof`; `fm-lock-lib.sh` fails safe and never removes a lock. | accept |
| 11 | Claude Code hook execution | **PASS** | Throwaway `.claude/settings.json` hook under `claude -p`: ran in `/usr/bin/bash` 5.2 (MINGW64), `CLAUDE_PROJECT_DIR=C:/Users/...` (forward slashes), `exec "$CLAUDE_PROJECT_DIR"/bin/probe.sh` succeeded, `CLAUDECODE=1` present. | none |
| 12 | MSYS argument path conversion | **FAIL** | As received by `herdr.exe`: `/clear` → `C:/Program Files/Git/clear`, `--match=/x` → `--match=X:/`, `/tmp/x` → `C:/Users/ebatt/AppData/Local/Temp/x`. `MSYS_NO_PATHCONV=1` or `MSYS2_ARG_CONV_EXCL=*` stops it. `--cwd /c/Users/x` → `C:/Users/x` is the one conversion that is wanted. | PR-3 |
| 13 | Pane cwd tracking | **FAIL, mechanism found** | `pane get .foreground_cwd` is always `null` on the Windows build (the smoke test's one failure). `pane get .cwd` is live: herdr injects a pwsh prompt hook that emits `ESC]9;9;<path>ESC\` after each prompt. A Git Bash child started with `PROMPT_COMMAND='printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"'` moved `.cwd` through `cd /c/Users/ebatt/dotfiles` and `cd /tmp` exactly. `pane process-info` lists only the pwsh root in `foreground_processes`. | PR-4 |
| 14 | Universal toolchain | **PASS** | After dotfiles PR #3: `FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip bin/fm-bootstrap.sh` in the live home prints only the herdr auto-detect NOTICE (zero MISSING, no TANGLE with `origin/HEAD` = `windows`). | dotfiles PR #3 |
| 15 | Treehouse lease | **PASS** | Windows treehouse 2.3.0 has `get --lease`, `--lease-holder`, `--json`. | none |
| 16 | herdr protocol floors | **PASS** | 0.8.2, protocol 20, `compatible: true`. | none |
| 17 | coreutils and friends | **PASS** | `mktemp`, `stat -c`, `timeout`, `realpath`, `install`, `column`, `fold`, `tput`, `perl`, `shasum`, `sha256sum`, `openssl`, `base64`, `mkfifo`, `/proc/<pid>/stat` all present. | none |
| 18 | no-mistakes | **PASS** | Native `claude.exe` + `agent_path_override` (dotfiles P4). | none |
| 19 | Install helpers / bootstrap hints | **DEGRADED** | `uname -s` = `MINGW64_NT-10.0-26200`; CI-only installers die "unsupported platform"; bootstrap prints `brew install` hints. | optional |
| 20 | Wedge alarm notifier | **DEGRADED** | No OS notifier on Windows. | dotfiles nicety (Phase C) |
| 21 | POSIX mode privacy checks | **FAIL (cross-cutting)** | 33 of 151 `bin/*.sh` create or assert mode-700/600 private state; every such check misfires on `noacl` mounts (rows 9, the `fm-x-mode` and `fm-test-run` test failures are all instances). A process-local `mount -o binary,posix=0,acl <ntfs dir> /mnt/p` made `mkdir -m 700` succeed with `stat` reporting 700, inherited by a child bash; `chmod 600` on a file returned EINVAL in that process-local mount and needs re-measuring under a real `/etc/fstab` mount (admin). | decision D6: targeted `acl` fstab mounts vs. an upstream shared helper |
| S | Real-herdr smoke test | **14 / 15** | `tests/fm-backend-herdr-smoke.test.sh` against an isolated lab session: version check, container ensure (idempotent), task tab create/prune/refuse/replace, secondmate workspace isolation, restart survival, `send_text_line`, `send_literal` + Enter all pass; `current_path` fails (row 13). 25 s wall. | rows 9, 13 |
| L | Portable test lanes | see below | `bin/fm-test-run.sh --check-coverage` → `ok total=167 parallel=24 serial=131 serial_shards=4 herdr=12`. | Phase B tracks the count |

## Portable lane results

Lanes were run with `--per-script-timeout-secs 300`; results are appended here as they finish.
Each red script is classified as product (a real Windows defect in `bin/`), test (an assumption of the test harness itself), or platform (a documented degradation), before Phase B chases it.

Both lanes ran with `MSYS=winsymlinks:nativestrict` exported (an earlier attempt without it added symlink-copy failures such as `ln: failed to create symbolic link .../fakebin/printf`, which the env var removes).
Wall time is roughly 10x Linux because every process spawn crosses the MSYS/Win32 boundary.

### portable-parallel-2: 6 green / 7 red of 13 (670 s)

| Script | Result | First failing assertion | Class (provisional) |
| --- | --- | --- | --- |
| fm-send-popup-settle, fm-tmux-submit-busy, fm-send-settle, fm-send-strict, fm-spawn-batch, fm-supervision-instructions | **PASS** | | |
| fm-backend-herdr | FAIL | "the ambiguity refusal did not name the candidate workspaces (missing: 'w1 w7')", yet the captured stderr names `(w1 w7)` | **product** - NOT resolved in slice 3 (that verdict was wrong); settled in slice 6: a native `jq.exe` writes CRLF, so the two-row read is `w1\r\nw7` and the refusal renders `w1\r w7`. Still red; the fix is a PR-3 follow-up |
| fm-arm-pretool-check | FAIL | "D01 via codex must deny, got exit 0" for `bin/fm-watch-arm.sh &` | **product** - resolved in slice 4: the watcher seatbelt was inert on Windows for three separate reasons (`node:path`, MSYS argument conversion, `jq` CRLF); now 145/145 |
| fm-crew-state | FAIL | "timed-out no-mistakes falls back to pane (missing: 'state: working')" | **test** - resolved in slice 6: `make_no_timeout_toolbin`'s symlinked MSYS binaries became the child's whole `PATH`; now green |
| fm-herdr-lab | FAIL | "timed-out provision must fail: expected exit 1, got 0" | **test + product** - resolved in slice 6: the fixture raced the poll loop, and removing the race exposed a cross-platform cancellation bug in `fm_herdr_lab_provision`; now 7/7 |
| fm-pr-merge | FAIL | "github-zero-exit-queue-required: refusal did not name the concrete observed state" | **platform: row 21** - settled in slice 6: `fm_pr_poll_prepare`'s mode-600 check, so `error: could not prepare PR poll`. The D6 trigger for Phase C |
| fm-ensure-agents-md | FAIL | "CRLF AGENTS.md injection did not preserve CRLF line endings" | **product** - resolved in slice 6: Git for Windows' grep, sed and awk strip a trailing CR, so the CRLF probe was always false; now green |
| fm-composer-lib | FAIL | "a half-block rule row must count as a structural edge" | **test** - resolved in slice 6: bash does not expand `\uHHHH` without a UTF-8 `LANG`, so the fixture held literal escape text; now green |

### portable-parallel-1: 5 green / 5 red / 1 gate-skip of 11 (903 s)

| Script | Result | First failing assertion | Class (provisional) |
| --- | --- | --- | --- |
| fm-composer-ghost, fm-grok-harness, fm-review-diff, fm-brief, fm-transition-lib | **PASS** | (fm-grok-harness passes only with `MSYS=winsymlinks:nativestrict`) | |
| fm-pi-primary-types | gate-skip | pi not installed | |
| fm-x-mode | FAIL | "poll auth error must write a dedupe marker" (next assertion wants `state/` at mode 700) | platform: row 21 |
| fm-cd-pretool-check | FAIL | "transport must fail open when node is unavailable: expected exit 0, got 127" | **test** - resolved in slice 4: a curated `PATH` of symlinked MSYS binaries cannot load `msys-2.0.dll`, so the child dies before the guard runs; the guard itself fails open correctly |
| fm-captain-hold-lifecycle | TIMEOUT | exceeded the 300 s per-script bound (failed in 11 s without the env var) | **product + platform** - settled in slice 6: not a hang. `fm-procevent.sh start` died on `ps -o pgid=` (fixed), and the script needs 1091 s here, so the bound was too small. Now 17/17 |
| fm-test-run | FAIL | "isolation failure: worker root mode is 755, expected 0700" | platform: row 21 (the runner's own `--jobs` isolation check) |
| fm-lint | FAIL | "installer did not fall back to shasum -a 256" | **test** - resolved in slice 5: the test stubs `uname`, so row 19 was the wrong verdict; the cause is a fakebin of symlinked MSYS binaries with no `msys-2.0.dll` (slice 4's finding). Now 28/28 |

### Count to beat

11 green, 12 red, 1 gate-skip across the 24 portable-parallel scripts, plus 14 of 15 in the real-herdr smoke test.
Of the 12 red, 3 are row 21 (POSIX modes), 2 were the guard fail-open suspects (`fm-arm-pretool-check`, `fm-cd-pretool-check`, both green after slice 4), 1 is `fm-lint` (green after slice 5), 1 is a timeout, and 5 needed a first look.
Slice 6 settled every one of them; the standing count is **19 green, 4 red, 1 gate-skip**, and all four remaining reds are named in "Phase B slice 6" below.
The 134-script portable-serial lane was not run in Phase A (roughly 3 hours at this box's spawn rate); it is still the next unit of work.

## Phase B slice 1 (PR-2): process identity and liveness

Measured 2026-08-29, same machine and toolchain as Phase A.
Rows 2 and 3 of the ledger are closed by `bin/fm-proc-lib.sh`, wired into `bin/fm-harness.sh`, `bin/fm-session-lock-lib.sh` and `bin/fm-wake-lib.sh`.
`bin/fm-backend.sh`'s only `ps` use is inside `fm_backend_detect_cmux_app_is_ancestor`, reachable solely from `fm_backend_detect_cmux_fallback`, whose first line is `[ "$(uname 2>/dev/null)" = Darwin ] || return 1` (bin/fm-backend.sh:174), so it has no non-Darwin path and is untouched.

### The plan's CIM sketch was 25x too slow

The plan sketched one `Get-CimInstance Win32_Process -Filter "ProcessId=N"` per hop and estimated ~300 ms.
Timed here against the real six-hop chain (bash -> bash -> claude.exe -> node.exe -> pwsh.exe -> herdr.exe):

| Approach | Wall time |
| --- | --- |
| one filtered `Get-CimInstance` per hop (the sketch) | 22.0 / 23.2 / 24.1 s |
| one bulk `Get-CimInstance Win32_Process` for the whole table | 4.7 / 5.1 s |
| `Get-Process -Id` plus repeated `.Parent` | 0.96 s |
| bare `pwsh -NoProfile -NonInteractive -Command 1` (the floor) | 0.75 / 0.79 s |
| reading `.CommandLine` off each PS7 Process object | 38.3 s |
| `ps -W` | 0.91 s |

`.CommandLine` on a PowerShell 7 `Process` is a hidden per-process CIM query, which is where the 38 s goes, so it is not read at all.

### `.Parent` alone cannot walk out of a Git Bash child

`Get-Process -Id <winpid>` on the interactive tool shell walked the full chain, but the same call from any `bash script.sh` or `bash -c` CHILD returned a null `.Parent`.
The child's recorded Win32 parent exists but is dead - MSYS emulates `fork()`, so the Win32 parent of a bash-spawned process is a transient that has already exited.
`Get-CimInstance` reports the same dead `ParentProcessId`, so this is not a `.Parent` artifact.

```sh
# from a child shell: CIM PPID 288144, Get-Process -Id 288144 -> nothing
bash -c 'W=$(cat /proc/$$/winpid); pwsh -NoProfile -NonInteractive -Command "
  \$c = Get-CimInstance Win32_Process -Filter \"ProcessId=$W\"; \$c.ParentProcessId"'
```

What does work is the MSYS process table, which has correct PPIDs *between MSYS processes* and only loses the trail at the boundary (PPID 1).
So the walk is hybrid, and the MSYS half is not just correct but free - MSYS `/proc/<pid>/` carries `exename` (exactly what `ps -o comm=` prints), `ppid`, `winpid`, and the real NUL-separated `cmdline`:

```sh
$ ls /proc/$$/
cmdline  ctty  cwd@  environ  exe@  exename  fd/  gid  maps  mountinfo  mounts
pgid  ppid  root@  sid  stat  statm  status  uid  winexename  winpid
$ cat /proc/$$/exename   # -> /usr/bin/bash   (no trailing newline)
```

Those files carry no trailing newline, so `read -r x < file` sets the variable and *then* reports EOF; the value, not `read`'s status, is what says whether it worked. That cost one debugging round.

Measured result of the hybrid walk, from a script two bash levels down:

```
/proc segment (2 hops, 64 ms)   59037 -> 59034, boundary winpid 263684
pwsh segment (5 hops, 828 ms)   263684 -> 168628 -> 283196 claude.exe
                                -> 186224 node.exe -> 178968 pwsh.exe -> 215332 herdr.exe
```

### The memo has to be primed by the caller

Every caller reads fields inside `$(...)`, and a subshell cannot write back to its parent, so a memo filling itself lazily would be discarded on every hop and the walk would cost one pwsh process per field.
Each caller therefore gains exactly one line, `fm_proc_chain_prime "$pid"`, before its loop; on macOS and Linux that line returns 0 without forking.
`tests/fm-proc-lib.test.sh` asserts the cost contract directly by counting invocations of a fake `pwsh`.

### The branch is chosen by capability, not by uname

An early version keyed only on `uname -s`. That silently broke every test in `tests/` that shims a `ps` to model a process table: on Windows the library ignored the fixture and walked the real tree.
The final version asks `uname` first and then, only if that said Windows, probes `LC_ALL=C ps -o comm= -p $$`; a `ps` that accepts `-o` wins.
macOS and Linux never run the probe (~90 ms, MSYS only). The `LC_ALL=C` pin is not cosmetic: `tests/fm-watcher-lock.test.sh` records the locale its stub `ps` was called under and fails if any call arrives without the pin.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh <every touched file>` | clean (ShellCheck 0.11.0, full extended analysis) |
| `tests/fm-proc-lib.test.sh` | 13 / 13, both branches |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `bin/fm-harness.sh` with every marker unset | `claude` in 2.4 s (was `unknown`) |
| `fm_harness_ancestry_pid` | `283196`, claude.exe's Win32 pid (was: could not resolve) |
| `tests/fm-grok-harness.test.sh` | green before and after |
| `fm-session-lock-ancestry`, `fm-secondmate-harness`, `fm-kimi-harness`, `fm-procevent`, `fm-backend-herdr`, `fm-test-run` | fail at the identical assertion before and after, in a worktree at `HEAD` |
| `tests/fm-watcher-lock.test.sh` | one real regression, found and fixed (the locale pin above); now fails only at the pre-existing concurrency assertion |

A bare `bin/fm-lint.sh` on this branch exits 0 while seeing NONE of this patch.
On a non-default branch it runs changed-mode and builds its roots from `git diff --name-only <merge-base>` (bin/fm-lint.sh:239), which cannot see untracked files, and both new files were untracked.
Passing the paths explicitly reported SC2034, SC1007 and SC2016 - all real, all now fixed.
Lint every new file BY PATH before trusting a green run on this branch.

### `--jobs N` with N>1 cannot be used on Windows

The first attempt to re-run the lanes used `--jobs 4` and returned 24 failed of 24, including scripts that were green in Phase A and one that was a gate-skip.
The cause is the runner's own per-worker isolation check, which is an instance of row 21:

```
fm-test-run: isolation failure: worker root mode is 755, expected 0700 (/tmp/fm-test-run.OMvN8M/w7)
```

Every worker root is created at mode 700 and re-read; on a `noacl` mount it reads back 755 and the runner aborts the shard, so a concurrent lane run reports a whole-lane failure that says nothing about the scripts.
Windows lanes must run serially until D6 is decided, and the Windows CI lane in slice 5 must not pass `--jobs`.

A serial re-run was started and stopped after 3 of 24 scripts (`fm-backend-herdr`, `fm-arm-pretool-check`, `fm-crew-state`, 6 minutes for those three).
All three failed at the same assertion Phase A recorded, which is consistent with no regression, but a full lane count is slice 6's deliverable and is NOT claimed here.
This slice's no-regression evidence is the per-script before/after comparison in the table above, taken against a `git worktree` at `HEAD`.

### Known consequence, not fixed here

On MSYS the session lock necessarily records the harness's WIN32 pid, because a native `claude.exe` has no MSYS pid at all.
`fm_harness_pid_alive` and `fm_pid_alive` handle that.
`bin/fm-lease-lib.sh:147` still probes the same pid with a bare `kill -0` inside `fm_lease_live`, so on Windows a live Pi lease reads as stale.
That fails CLOSED, is gated on `PI_CODING_AGENT`/`FM_SUPERVISION_ACTOR` (bin/fm-lease-lib.sh:140-143), and Pi is not installed on this machine, so it is recorded here rather than folded into a patch whose blast radius is meant to be four files.

## Phase B slice 2 (PR-3): the Windows-aware herdr CLI

Closes rows 5, 9 and 12, and removes row 8's `/`-prefix half.
Four changes, all in `bin/backends/herdr.sh` except the last, all keyed on a capability rather than on `uname`.

### Socket identity (row 5)

`fm_backend_herdr_canonical_socket_path` now accepts a `[A-Za-z]:[/\]`-shaped path and folds it through `cygpath -u`, and refuses it when there is no `cygpath` - a shell that cannot read that spelling is not looking at an absolute path, it is looking at a relative one with a colon in it, and it refuses exactly as it did before.
That refusal is what keeps a POSIX host byte-identical; an earlier version of this slice returned such a path literally and quietly changed which error a Linux host printed.
Both sides of the launcher's same-session proof - the `HERDR_SOCKET_PATH` herdr injects into a pane and the `socket_path` it reports in `session list --json` - come back through the same function, so they reduce to one identity.

```
$ herdr session list --json | jq -r '.sessions[]|select(.name=="default")|.socket_path'
C:\Users\ebatt\AppData\Roaming\herdr\herdr.sock
$ bash -c '. bin/backends/herdr.sh; fm_backend_herdr_presentation_session_socket_path default'
/c/Users/ebatt/AppData/Roaming/herdr/herdr.sock     # was: refused
```

The comparison itself moved into `fm_backend_herdr_socket_paths_equal`, which folds case only when `cygpath` exists - the marker for a Windows userland, where the filesystem underneath is case-insensitive and `C:\Users` and `c:\users` are one socket.
The fold runs only after a byte comparison has already failed, so a case-sensitive host is untouched.

### The presentation lock namespace (row 9)

`fm_backend_herdr_presentation_lock_namespace_valid` still requires owner identity unconditionally.
The mode check is now conditional on the mode meaning something: when the directory does not read 700, `fm_backend_herdr_presentation_lock_namespace_modeless` creates one `mktemp -d` probe directory and reads its mode back.
Only a filesystem that drops the mode answers with anything but 700, and a genuinely group-readable namespace on a mode-capable filesystem still fails, because there the probe reads back the 700 it asked for.

The probe is created BESIDE the namespace, never inside it, and that placement is the whole security argument.
The probe only ever runs when the namespace is not 700 - which is exactly the state in which an attacker may have write access to it - so a probe directory placed *inside* the namespace at a predictable name (`$$` is readable from `/proc`) could be pre-created by that attacker as a mode-000 or symlinked directory, surviving both the `rm -rf` and the `mkdir`, and answering "this filesystem drops modes" on a Linux box where it does not.
`mktemp -d` in the namespace's parent removes both halves of that: the name is unpredictable, and the parent is `/tmp`, whose sticky bit stops anyone but the owner removing or renaming the entry.

This is not a weakening of the privacy claim on Windows so much as a relocation of it: `/tmp` is `C:\Users\ebatt\AppData\Local\Temp`, which NTFS makes private to the user by ACL, and the `noacl` mount means no POSIX mode can be written there by anyone, attacker included.
One deliberate widening to flag for review: the key is the capability ("this filesystem cannot carry a mode"), not the platform, so a Linux host whose `/tmp` sat on vfat or exfat would also take the relaxation.
That is the same principle slice 1 settled on, and on such a mount the 700 requirement is unsatisfiable rather than protective - but it is broader than the plan's "when the mount reports noacl" wording, so it is called out rather than buried.

```
$ bash -c '. bin/backends/herdr.sh; fm_backend_herdr_presentation_session_lock_path default'
/tmp/firstmate-herdr-presentation/order-24573fab66d57ed002cb6d72a028d5ef.lock   # was: refused
```

The three `herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close` warnings the real-herdr smoke test printed in Phase A are gone.
Per the plan this relaxation is confined to this one site; the other 32 mode-700 sites in `bin/` remain decision D6.

### MSYS argument conversion (row 12)

`fm_backend_herdr_cli` now routes through `fm_backend_herdr_cli_win32` when `fm_backend_herdr_win32_cli` says the `herdr` on PATH is a native Win32 binary.
That branch sets `MSYS2_ARG_CONV_EXCL='*'` for the whole call and converts `--cwd` (both the `--cwd <path>` and `--cwd=<path>` spellings) itself with `cygpath -w`, which is exactly the split the Phase A finding asked for.

```
$ herdr tab list --workspace /clear --session default
{"error":{"code":"workspace_not_found","message":"workspace C:/Program Files/Git/clear not found"}}
$ MSYS2_ARG_CONV_EXCL='*' herdr tab list --workspace /clear --session default
{"error":{"code":"workspace_not_found","message":"workspace /clear not found"}}
```

`MSYS_NO_PATHCONV` is deliberately not used: setting it to an EMPTY value also disables conversion, which makes it a trap inside a wrapper.

### The probe that keeps every existing test honest

`fm_backend_herdr_win32_cli` asks whether `command -v herdr` resolves to a file whose first two bytes are `MZ`.
That is not a proxy for Windows - it is the exact condition under which MSYS converts arguments, because MSYS converts for native binaries and not for the MSYS shell scripts it runs itself.
Which means the fake `herdr` that every unit test in `tests/` puts on PATH keeps the plain branch, on Windows too, and goes on asserting the byte-exact argument lists it always did.
This is the same lesson slice 1 recorded about `uname`, arrived at from the other direction.
`FM_BACKEND_HERDR_WIN32_CLI=1/0` forces the answer so a test can drive the conversion branch with a shell-script fake.

### The workspace mover (row 8)

`bin/backends/herdr-workspace-move.py` accepts the same Windows path shape, and returns its existing "invalid transport" status 2 when `socket.AF_UNIX` is absent instead of raising `AttributeError`.
The adapter itself now hands it the already-folded `/c/...` path, so the shape acceptance only matters when the helper is run directly, as its own docstring describes; the `AF_UNIX` guard is the part that runs.
Windows CPython still has no `AF_UNIX`, so ordering still degrades to a warning; row 8 stays DEGRADED, but for the one honest reason rather than two.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on all three touched shell files | clean (ShellCheck 0.11.0, full extended analysis) |
| `python3 -m py_compile bin/backends/herdr-workspace-move.py` | clean |
| `tests/fm-backend-herdr-windows.test.sh` (new, 21 cases) | 21 / 21 on Windows (one documented skip: MSYS will not put an empty file on PATH) |
| `bin/fm-test-run.sh --check-coverage` | `ok total=169 parallel=24 serial=133 serial_shards=4 herdr=12` |
| `tests/fm-backend-herdr.test.sh` | fails at the identical assertion as Phase A (`the ambiguity refusal did not name the candidate workspaces`), 19 cases in |
| `tests/fm-backend-herdr-smoke.test.sh` (real herdr, isolated lab session) | same 13 passes and the same single row-13 failure as Phase A, now with zero presentation-lock warnings |

One shellcheck lesson: adding a local named `probe` to this file made SC2100 fire on an unrelated pre-existing line, `identity=probe-absent`, which ShellCheck then read as arithmetic on a known variable.
The local is `probe_dir`.

One `set -u` lesson, caught by making the new test file run every snippet under `set -u`: `local magic` followed by a `read` that never fires leaves the variable UNSET, not empty, and the next `[ "$magic" = MZ ]` aborts the whole script with "unbound variable".
Every local whose only assignment is a command that may not run has to be initialized at the `local`.

### What the acceptance review changed

An adversarial review of the slice before it landed produced two changes that are already in the numbers above, both in the direction of "do less on a POSIX host":
the `mktemp -d` probe placement described under row 9, and the `cygpath`-required refusal described under row 5.
It also confirmed the parts that do not move: on a POSIX host the new `fm_backend_herdr_cli` gate is two `command -v` builtins and no extra process, `fm_backend_herdr_socket_paths_equal` reaches its `tr` fold only where `cygpath` exists, and the `--cwd` handling covers every shape the ~70 call sites in this adapter actually emit.

Two accepted limitations, recorded rather than fixed:
a `pane send-text` payload that is literally `--cwd=<path>` would be converted (the scan is positional-blind), which is contrived and strictly better than the pre-change MSYS behavior;
and a `herdr` installed as a `.bat`/`.cmd` shim would be native to MSYS without being a PE image, so it would take the plain branch and get its arguments mangled - the official installer ships an `.exe`.

### Not fixed here

`tests/fm-backend-herdr.test.sh`'s ambiguity-refusal assertion fails on Windows against stderr that visibly contains the expected `w1 w7`.
It is unchanged by this slice and belongs to slice 6's triage, but it is worth naming: it stops the largest herdr test 19 cases in, so its true Windows pass count is still unknown.

## Phase B slice 3 (PR-4): the crewmate pane on MSYS

Rows 6 and 13 are one problem with two halves: herdr opens every Windows pane in `pwsh` and has no per-tab shell flag, and the only cwd field that moves on Windows is the one the adapter was told never to read.
Both halves are now handled inside `bin/backends/herdr.sh`, and the acceptance run below shows them working together against a real herdr.

### One funnel for every task pane (row 6)

`tab create --workspace W --cwd C --label L --no-focus` appeared inline at three sites - the plain spawn path, the presentation projection, and the projection's husk replacement.
All three produce a pane an agent is later launched into, so all three need the same treatment; they now go through `fm_backend_herdr_task_tab_create`, which emits exactly that argument list on a POSIX host and nothing else.
`tests/fm-backend-herdr.test.sh`'s existing byte-exact assertions on that line are what proves the POSIX call did not move, and they still pass.

On MSYS the same function adds two `--env` flags and then sends the pane's first command:

```sh
herdr tab create --workspace W --cwd C --label L \
  --env "SHELL=C:\Program Files\Git\usr\bin\bash.exe" \
  --env 'PROMPT_COMMAND=printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"' \
  --no-focus
herdr pane run <pane> "& 'C:\Program Files\Git\usr\bin\bash.exe' --login"
```

The launch line is pwsh's call operator because the measured alternatives do not work: `exec bash -l` fails (`exec` is not a pwsh command) and a bare `bash` is WSL's bash, not Git Bash.
The path is not a constant; it is `cygpath -w "$BASH"`, the Windows spelling of the very interpreter firstmate is running in, so a Git installed anywhere still resolves.
`cygpath -w` supplies the `.exe` suffix on its own: `cygpath -w /usr/bin/bash` prints `C:\Program Files\Git\usr\bin\bash.exe`.

The branch is keyed on `fm_backend_herdr_win32_pane_bash`, which is `fm_backend_herdr_win32_cli` (slice 2's PE-magic probe) plus the path.
That is the same capability-not-platform rule slices 1 and 2 established, and it is what keeps every unit test's shell-script `herdr` fake on the plain branch while running on Windows.

### The environment is the carrier, not the keyboard (row 13)

`PROMPT_COMMAND` is passed through `--env` rather than typed into the pane, and that is the load-bearing choice.
`treehouse get` does not `cd`; it spawns a **fresh** shell inside the worktree, and a variable typed into the outer bash would not be in that child's environment.
Arriving through `tab create --env` it is exported the whole way - herdr to pwsh to Git Bash to treehouse's subshell - so the emitter is still running in the exact shell whose cwd `fm-spawn.sh` is waiting to see.
Verified on this machine: nothing in Git Bash's login chain (`/etc/profile`, `/etc/profile.d/*.sh`, `~/.bash_profile`, `~/.bashrc`) assigns `PROMPT_COMMAND` or `cd`s away from the pane's `--cwd`, so `--login` neither clobbers the emitter nor loses the project directory.

`SHELL` is set for treehouse's benefit: it is a native Windows binary, and a POSIX `/usr/bin/bash` is not something it can spawn.
Handing a bash session a Windows-spelled `SHELL` is only safe because nothing in `bin/` or `.agents/` reads `$SHELL` at all - checked, zero hits - so the only consumer is the one it is aimed at.

`fm_backend_herdr_current_path` now reads both fields from **one** `pane get` and falls back from `.foreground_cwd` to `.cwd`, folded back through `cygpath -u`.
The fallback is gated on the pane host, never on "`foreground_cwd` came back empty".
That distinction is the safety argument: on a POSIX host an empty `foreground_cwd` means the read failed, and `.cwd` there really is the frozen creation-time value the original comment warns about, so substituting it would hand `fm-spawn.sh`'s worktree poll and the relaunch check a path the pane may have left long ago.
On Windows `.cwd` is not a snapshot at all - it is the last path the pane's shell reported over OSC 9;9 - which is why the emitter above has to exist for the fallback to mean anything.
One `pane get` rather than two also means the two fields cannot disagree about a pane that is moving.

### Acceptance run (lab session, real herdr 0.8.2)

An isolated `fm-lab-pr4-*` session, provisioned and torn down with `bin/fm-herdr-lab.sh`; the default session was never touched and no server was stopped.
The probe called the shipped adapter functions directly.

```
win32_cli: yes
pane_bash: C:\Program Files\Git\usr\bin\bash.exe
workspace=w1 seeded_tab=w1:t1
tab=w1:t2 pane=w1:p2

-- pane transcript after task_tab_create --
> & 'C:\Program Files\Git\usr\bin\bash.exe' --login
ebatt@GeneralBerserk MINGW64 ~/firstmate-gnhf (gnhf/objective-finish-the-589b84)
$

-- before treehouse get --
current_path=[/c/Users/ebatt/firstmate-gnhf]
{"cwd":"C:\\Users\\ebatt\\firstmate-gnhf","foreground_cwd":null}

-- treehouse get, then poll --
moved after 3s: /c/Users/ebatt/.treehouse/firstmate-gnhf-503d65/1/firstmate-gnhf
{"cwd":"C:\\Users\\ebatt\\.treehouse\\firstmate-gnhf-503d65\\1\\firstmate-gnhf","foreground_cwd":null}

-- pane transcript tail --
$ treehouse get
[tree] Entered worktree at ~\.treehouse\firstmate-gnhf-503d65\1\firstmate-gnhf. Type 'exit' to return.
ebatt@GeneralBerserk MINGW64 ~/.treehouse/firstmate-gnhf-503d65/1/firstmate-gnhf ((4f38fc5...))
$

-- what that path actually is --
git rev-parse --show-toplevel   C:/Users/ebatt/.treehouse/firstmate-gnhf-503d65/1/firstmate-gnhf
git rev-parse --git-common-dir  C:/Users/ebatt/firstmate-gnhf/.git
```

That is the acceptance test: the first pane command produced a Git Bash prompt, `treehouse get` ran in it, and three seconds later the pane's `.cwd` was the worktree and `fm_backend_herdr_current_path` reported it as a POSIX path a comparison can use.
`foreground_cwd` stayed `null` throughout, confirming row 13's measurement rather than working around a transient.
The emitter surviving into treehouse's own subshell - the hop that a typed `PROMPT_COMMAND` would not have survived - is what the last two lines prove.

### New finding: Windows `jq` writes CRLF

Not a row in the plan, found while verifying this slice, and it is the reason `tests/fm-backend-herdr.test.sh` stops 19 cases in on Windows.

`jq` on Windows puts stdout in text mode, so every record it prints ends `\r\n`:

```sh
$ printf '{"a":["x","y"]}' | jq -r '.a[]' | od -c
0000000   x  \r  \n   y  \r  \n
```

Both builds present on this machine do it (anaconda's mingw-w64 `jq-1.6` and WinGet's `jq-1.8.2`), so it is the platform's behavior and not a bad package.

The saving grace is narrow but real: MSYS bash strips the trailing `\r\n` in command substitution, so every **single-value** `jq` read - the overwhelming majority in this adapter - is already correct on Windows.
Only **multi-line** reads are damaged, and only in their non-final records:

```sh
$ m=$(printf '{"a":["w1","w7"]}' | jq -r '.a[]'); printf '[%s]' "${m//$'\n'/ }" | od -c
0000000   [   w   1  \r       w   7   ]
```

That is exactly the ambiguity-refusal assertion that fails: `bin/backends/herdr.sh:1974` builds its message from a multi-line `jq` read, and the message really does contain `w1\r w7`.
The consequence is worse than a test failure wherever such a value is fed back to herdr - `herdr tab close "w1:t2\r"` is not a tab id - so this is a product defect on Windows, not a fixture assumption.
`bin/backends/herdr.sh` has eight `jq -r` reads of an iterated array (husk tab ids, projection pane ids, workspace id lists), and other `bin/` scripts have their own.
It is slice 6's, not this slice's: the fix is one decision about where to normalize, and it must not cost a process per call on macOS and Linux.

Two facts to build that fix on: `jq --raw-output0` (1.7+) is not available on the `jq-1.6` this machine resolves first, and the CR is produced by `jq` itself, so no MSYS mount option or shell flag suppresses it.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh bin/backends/herdr.sh tests/fm-backend-herdr-windows.test.sh` | clean (ShellCheck 0.11.0, full extended analysis) |
| `tests/fm-backend-herdr-windows.test.sh` (21 cases + 11 new) | 32 / 32 on Windows |
| `tests/fm-backend-herdr.test.sh`, POSIX identity of the refactored sites | all 16 `create_task` / `--no-focus` / husk-replacement cases and `current_path` pass |
| Lab acceptance run against real herdr | transcript above |
| `tests/fm-backend-herdr-smoke.test.sh` (real herdr, isolated lab session) | **16 / 16, exit 0** - was 14/15 in Phase A and 13 + the same single failure in slice 2 |
| `bin/fm-test-run.sh --check-coverage` | `ok total=169 parallel=24 serial=133 serial_shards=4 herdr=12` (no new file, unchanged) |
| `tests/fm-documentation-audiences.test.sh` | 4 / 4 - was red since Phase A |

That last row is a debt this port created and had not paid: `docs/windows/README.md` and `docs/windows/measurement.md` were added in Phase A without an entry in `docs/documentation-audiences.json`, and the audience check has failed on `unclassified:` ever since.
Both are now registered as `maintainer-verification`, in place, without reordering the file.
`docs/herdr-backend.md` also gains a "Windows (Git Bash / MSYS)" section covering all three slices' MSYS branches, which is what makes PR-4 self-contained upstream.

The smoke test is the number that matters most here.
Its one long-standing failure was `current_path did not report the pane's cwd after cd /tmp, got ''` - row 13 itself - and it is now green, which also means the run reaches the cases that were behind it.
The `/tmp` round trip is exact rather than lucky: `cygpath` reads the MSYS mount table, so `cygpath -u "$(cygpath -w /tmp)"` returns `/tmp`, not `/c/Users/ebatt/AppData/Local/Temp`.

The `tests/fm-backend-herdr.test.sh` row needed a workaround to reach those cases at all, because of the `jq` finding above.
The suite was run with a CR-stripping `jq` shim on `PATH` (`jq.exe "$@" | tr -d '\r'; exit "${PIPESTATUS[0]}"`), which is a measurement tool and is not committed.
With it the suite reached 114 passes and 0 failures before a 10-minute wall clock cut it off - and the cases this slice touches are all inside those 114.
Without it the suite still stops at case 20, unchanged by this slice.

### What the acceptance review changed

An adversarial review before the slice landed cleared (a) POSIX byte-identity across all three call sites, (b) the MSYS bootstrap ordering under `set -e`/`set -u`, and (c) the fallback gate, and found one confirmed mutation survivor plus five smaller things.
Four became changes:

- **The emitter was only tested up to the `=`.** The tab-create assertion matched the needle `--env<US>PROMPT_COMMAND=`, so gutting the emitter to the empty string passed all 31 cases while shipping a pane whose `.cwd` never moves - a 60-second spawn timeout naming the wrong cause. The assertion now matches the whole emitter and pins `--no-focus` behind it. Confirmed by mutation: replacing the emitter's body, and separately dropping the `$(...)` call from the `--env` argument, each now fail.
- **The funnel's success status was never asserted** in the only suite that runs clean on Windows. All three call sites branch on it, so a funnel that returned 1 on success would refuse every spawn that worked. One `expect_code 0` closes it, and mutation-fails as expected.
- **A single quote in the Git Bash path** would have produced a pwsh parse error that `|| true` swallowed. pwsh doubles a quote inside a single-quoted string, so the path is now `${bash_win//\'/\'\'}`. A per-user Git install under `C:\Users\o'brien\...` is the case; `C:\Program Files` installs never were.
- **A failed bootstrap was completely silent.** It still does not fail the spawn - `fm-spawn.sh`'s worktree poll is the real backstop - but it now prints a warning naming the pane and what the pane is still running, so the 60-second timeout downstream is not the first evidence.

Two more were tightened without changing the product: a crash-blind POSIX `current_path` case now also asserts that `pane get` actually ran, and the "no bootstrap on a non-PE herdr" case now demands exit **1** rather than any non-zero, so an adapter that failed to source no longer reads as a refusal.
A case for "tab create succeeded but the response carries no pane id" was added: the funnel returns success without bootstrapping, and the property worth pinning is that it never aims `pane run` at a guessed pane.

One finding is recorded rather than fixed, in a comment on `fm_backend_herdr_current_path` and here.
`.cwd` only advances when a prompt fires, so a pane whose foreground process left the worktree without a subsequent shell prompt still reports the last prompt's directory.
The spawn poll is unaffected - it waits for a change and requires two agreeing reads - but the relaunch check, which asks whether an adopted pane is STILL in its worktree, is genuinely weaker on Windows than on POSIX.
That is inherent to OSC 9;9 rather than to the fallback: `.foreground_cwd`, the field that would answer exactly that question, does not exist on the Windows build at all.

One test-fixture lesson, found while hardening: `"${VAR:-{"result":{...}}}"` does not work.
The braces inside the JSON close the parameter expansion early and the fake returns a truncated response, which in this case silently removed the pane id and therefore the whole bootstrap the test was asserting.
A default that contains braces has to be an `if`.

### Not fixed here

`herdr tab create --env` is the only channel available, so a captain whose herdr `default_shell` is `cmd` rather than `pwsh` would get a first pane command in the wrong dialect.
The `& '<path>' --login` form is pwsh's, locked as D2, and the installed configuration here is `default_shell = "pwsh"`.

The bootstrap is fire-and-forget: `pane run` types the launch line immediately after `tab create` returns, with no wait for a prompt.
It worked on every run here, and `fm-spawn.sh`'s own 60-second worktree poll is the backstop if it ever does not, but a pane that swallowed its first line would fail with "treehouse get did not enter a worktree" rather than something that names the real cause.

## Phase B slice 4: the two PreToolUse guards

Phase A's red list carried two "guard fail-open suspects" (`fm-arm-pretool-check`, `fm-cd-pretool-check`) with the note "top of the Phase B list".
Both reproduced on this machine, and the verdict is **three product defects and one test-fixture assumption**, not the one-of-each the labels guessed.
All three product defects are Windows-only, and all three are in the direction that matters: a guard whose whole job is to refuse a command was refusing nothing, or refusing the wrong thing.

| Symptom | Verdict | Root cause |
| --- | --- | --- |
| `fm-arm-pretool-check`: "D01 via codex must deny, got exit 0" | **product** | `bin/fm-arm-command-policy.mjs` imported the platform-default `node:path`, which is `path.win32` on Windows |
| (found behind it) the A13/A06 class of allow cases denied | **product** | MSYS rewrites `--root /c/fm` to `C:/fm` before native `node.exe` sees it, while the command's own words stay POSIX |
| (found behind that) D24, and every multi-line command | **product** | a native `jq.exe` writes stdout in text mode, so an interior LF arrives as CRLF |
| `fm-cd-pretool-check`: "transport must fail open when node is unavailable: expected exit 0, got 127" | **test** | a curated `PATH` of symlinked MSYS binaries cannot load `msys-2.0.dll` |

### The watcher seatbelt was completely inert on Windows

`decision()` returns `allow` as soon as `analysis.protectedFound` is false, and that comes from `protectedIdentity(executable, root)`:

```js
const normalized = path.normalize(value);
if (normalized === relative || normalized === path.join(root, relative) || normalized.endsWith(`/${relative}`)) return kind;
```

On Windows, Node's default `path` export is `path.win32`:

```sh
$ node -e "const p=require('path'); console.log(JSON.stringify(p.normalize('bin/fm-watch-arm.sh')))"
"bin\\fm-watch-arm.sh"
```

So `normalized` never equals `bin/fm-watch-arm.sh`, never equals a `path.join` of a POSIX root, and never ends with `/bin/fm-watch-arm.sh`.
No protected script was ever recognized, and every deny case in the acceptance matrix - all of them, through all five harness entry forms - allowed:

```sh
$ node bin/fm-arm-command-policy.mjs --command 'bin/fm-watch-arm.sh &' --root "$PWD" --home "$PWD"
allow
$ printf '%s' '{"tool_name":"Bash","tool_input":{"command":"bin/fm-watch-arm.sh &"}}' | bin/fm-arm-pretool-check.sh; echo $?
0
```

The fix is one import: `import { posix as path } from "node:path";`.
Every path this policy compares is either a word lifted out of a POSIX shell command line or the `--root`/`--home` its POSIX-shell transport passes in, so `/` is the only separator in the domain, and on macOS and Linux `node:path` already **is** `path.posix` - naming it costs those hosts nothing.
The file's own `basename()` helper was already POSIX-only (`value.split("/")`), so this makes the module internally consistent rather than introducing a new convention.
`bin/fm-cd-command-policy.mjs` imports no path module at all and needed nothing.

### `--root` and `--home` arrived as Windows paths

With the import fixed the deny cases pass and the **allow** cases start failing - the mirror-image defect, one layer up.
MSYS rewrites every `/`-leading argument before a native Windows executable sees it (finding 12, measured at `herdr.exe`; `node.exe` is no different):

```sh
$ node -e 'console.log(JSON.stringify(process.argv.slice(2)))' --root /c/fm --home /c/fm --command 'source /c/fm/config/x-mode.env; x'
["--root","C:/fm","--home","C:/fm","--command","source /c/fm/config/x-mode.env; x"]
```

The command string survives - it contains spaces, so MSYS does not treat it as a path - but `--home` does not.
`xModePathAllowed` then compares `/c/fm/config/x-mode.env` from the command against `C:/fm/config/x-mode.env` from `--home`, the blessed `source config/x-mode.env` setup node stops being recognized, and a legitimate arm command is DENIED:

```sh
$ node bin/fm-arm-command-policy.mjs --command "source '$PWD/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180" --root "$PWD" --home "$PWD"
deny	watcher-bundled	a protected watcher command must be the sole final command after approved setup nodes
```

That is fail-closed rather than fail-open, but it is still the guard deciding on bytes the shell never had.
The same conversion rewrites a `--command` value that happens to be a single bare path, and the classifier's contract is to see exactly what the shell would run.

The fix is in the transport, where it belongs - the policy stays the sole owner of classification and is simply handed correct inputs.
`bin/fm-arm-pretool-check.sh` gained one MSYS-only branch just above the `node` call: convert the **policy script path** with `cygpath -w`, because that is the one argument that genuinely must be a Windows path (`node.exe` opens it), and export `MSYS2_ARG_CONV_EXCL='*'` so nothing else is touched.
That is the same shape PR-3 used for `fm_backend_herdr_cli`, for the same reason.
Without `cygpath` the branch does not fire and the call stays exactly what it was: a blanket `MSYS2_ARG_CONV_EXCL='*'` with an unconverted `/c/...` script path makes `node` look for `C:\c\...`, and the guard would then fail open on every command.

`bin/fm-cd-pretool-check.sh` passes no `--root`/`--home`, and a `cd` command is never a single bare path, so it needs no equivalent branch and did not get one.

### `jq` on Windows corrupts every multi-line command

Behind those two is a third, and it is the sharpest.
The slice-3 CRLF finding turns out to have a security consequence in the guards, not just a cosmetic one in the herdr adapter.

Both transports lift the command out of the PreToolUse payload with `jq -r`, and a native `jq.exe` opens stdout in text mode.
MSYS bash strips a trailing CRLF in command substitution, so a single-line command is exact - but a multi-line one is not:

```
# the value jq was given, then the value the transport got back
raw:  62 69 6e 2f 66 6d 2d 77 61 74 63 5c 0a 68 ...    bin/fm-watc \ LF h-arm.sh &
back: 62 69 6e 2f 66 6d 2d 77 61 74 63 5c 0d 0a 68 ... bin/fm-watc \ CR LF h-arm.sh &
```

`\` + LF is a shell line continuation, and the classifier joins it back into `bin/fm-watch-arm.sh`.
`\` + CR + LF is not.
So acceptance case D24 - the exact obfuscation the transport's prefilter comment promises to delegate to the classifier - was ALLOWED on Windows through every stdin entry form.
More broadly, any multi-line Bash tool call, an everyday shape, was classified from bytes the shell would never run.

The fix is a new `fm_hook_payload_string` in `bin/fm-hook-host-lib.sh`, which both transports already source at exactly the right point: after the `command -v jq` check and before the extraction.
On a Windows userland it undoes exactly jq's translation, every CRLF back to one LF; on a POSIX host it runs the same `jq -r` pipeline the callers always ran and returns jq's own status, so the documented fail-open is untouched.

The undo is lossless because text mode never touches a CR that is not immediately followed by an LF.
A command that already contained CRLF is written as CR CR LF and comes back as CR LF; a lone CR is written and returned unchanged.
Both are pinned by tests.

`jq 1.7` grew `--binary` for this, and it is deliberately not used: the `jq` this machine resolves first is `jq-1.6`, and a guard that silently stops correcting itself on an older jq is worse than a two-line substitution.

### The cd guard was right all along

`test_fail_open_missing_node` builds a directory of symlinks to `bash sh git dirname cat printf sed tr jq`, sets `PATH` to it alone, and expects the transport to exit 0 because `node` is absent.
On Windows it exits 127 with no output, before the transport runs a single line:

```sh
$ PATH="$fake" bash -c 'echo hi'
.../fake/bash: error while loading shared libraries: ?: cannot open shared object file
```

Windows resolves an MSYS or MinGW executable's DLLs against the directory the image was launched from and then against `PATH`.
A symlinked `bash.exe` in a fakebin that holds no `msys-2.0.dll`, reached through a `PATH` that is only that fakebin, cannot start.
Dropping `msys-2.0.dll` in gets `bash` running and then `dirname` dies on `msys-intl-8.dll`; `git.exe` from `/mingw64` needs a different set again.

The product is fine.
Given a fakebin the child can actually execute, the transport fails open exactly as documented, with no output and exit 0.

So this one is a **test-harness assumption**, and the fix is one helper rather than one edit.
`tests/lib.sh` gained `fm_fakebin_link <fakebin> <tool>...`: on macOS and Linux it makes the same symlink the open-coded loops made, and on a Windows userland it writes a one-line wrapper that execs the tool by absolute path, so the loader looks in the tool's real directory.
Eight test files open-code that loop; this slice converts the three in `tests/fm-cd-pretool-check.test.sh` and the one in `tests/fm-arm-pretool-check.test.sh` that its own red case needed, and leaves the rest to slice 6, which now has a one-line answer for them.

### The new branches are environment-gated, deliberately

All three Windows branches are selected by `$OSTYPE` (`msys*|mingw*|cygwin*`), the idiom `bin/fm-watch-arm.sh` already uses, because it is a shell variable and costs no fork on a hook that runs before every Bash tool call.
`$OSTYPE` is inherited, so whatever starts the hook can set it.
Forcing it on a POSIX host does two things: the CRLF undo runs, which can only make a CR-bearing command MORE likely to be read as a line continuation and therefore more likely to DENY; and the transport looks for `cygpath`, does not find it, and makes the unchanged call.
Neither direction opens a bypass.
The alternative, `uname -s`, costs a process per hook invocation and answers the same question less precisely.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on all eight changed shell files, by explicit path | clean (ShellCheck 0.11.0, full extended analysis) |
| `tests/fm-guard-windows-transport.test.sh` (new, 13 cases) | 13 / 13 on Windows |
| `tests/fm-cd-pretool-check.test.sh` | **13 / 13, exit 0** - was failing at case 11 |
| `tests/fm-arm-pretool-check.test.sh` | **146 / 146, exit 0** - was failing at case 37, on the first deny case of the acceptance matrix |
| `bin/fm-test-run.sh --check-coverage` | `ok total=170 parallel=24 serial=134 serial_shards=4 herdr=12` |
| Mutation: revert the `posix` import | the policy case fails (`expected exit 2, got 0`) |
| Mutation: drop the CRLF substitution | the first three payload cases fail |
| Mutation: drop `POLICY_ARG` + `MSYS2_ARG_CONV_EXCL` | the MSYS transport case fails |
| Mutation: drop the `[ -n "$POLICY_WIN" ]` guard | the blank-cygpath case fails |
| Mutation: swallow a failing `cygpath` | the failing-cygpath case fails |

`tests/fm-guard-windows-transport.test.sh` fakes the userland rather than requiring one: `$OSTYPE`, a `jq` that emits the exact bytes a text-mode stdout would, a `cygpath` that marks its answer, and a `node` that records its argv and whether `MSYS2_ARG_CONV_EXCL` reached it.
Both branches therefore run on Linux and macOS CI too, the way `tests/fm-proc-lib.test.sh` and `tests/fm-backend-herdr-windows.test.sh` already do.
Its four transport cases run with the fakebin as the child's **whole** `PATH`, so the "no cygpath" case really has no cygpath; on a Windows host the real one is otherwise still on `PATH` and the case passes for the wrong reason.

### What the acceptance review changed

An adversarial security review before the slice landed answered the question that mattered most - can any of the three fixes turn a DENY into an ALLOW on any platform - with a proof rather than an assertion, and found no HIGH or MED security finding.
The argument worth keeping: the top-level lexer already treats CR as whitespace (`bin/fm-arm-command-policy.mjs:199`), so `\r\n` and `\n` produce an identical token stream at top level and the CRLF undo is a no-op there.
It differs only inside a backslash escape or inside quotes, and there it can only *reconstruct* a protected identity - `bin/fm-watc\` + LF becomes `bin/fm-watch-arm.sh` - which moves allow to deny.
It cannot remove a `&`, a `|`, or a redirection, because it rewrites nothing but `\r\n`.
So `policy(undo(CMD)) = allow` implies `policy(CMD) = allow`, and an `$OSTYPE=msys` spoof on a Linux host buys an attacker nothing.

Three coverage gaps became three new cases, each mutation-verified:

- **`cygpath` answering with a blank line** was unpinned. Taking that answer would hand `node` an empty script path with conversion already disabled - no policy, and a guard that allows everything. Deleting the `[ -n "$POLICY_WIN" ]` guard now fails a case.
- **`cygpath` present but exiting non-zero** was unpinned; only its total absence was covered. Swallowing that failure now fails a case.
- **`fm_fakebin_link`'s absolute-path skip** was unpinned, so a shell builtin (`command -v printf` answers `printf`, not a path) would have been placed as a broken entry on a child's whole `PATH`.

One finding is recorded rather than fixed, in the test's own comment: the `posix` import is the one fix in this slice that **cannot** be faked onto a POSIX host.
Node keys its `path` export off `process.platform`, not off anything in the environment, so on Linux and macOS the default export already is `path.posix` and reverting the import cannot fail any test there.
Only a Windows leg catches that regression, which is one more argument for slice 5's CI lane.

### Not fixed here

If `cygpath` is ever unavailable on a Windows host, the transport keeps the plain call, which is the safe direction for a protected command but silently reintroduces the false DENY of a blessed `source <home>/config/x-mode.env` arm.
It is not warned about, because both transports' contract is that an ALLOW writes nothing to stdout or stderr and the suites assert exactly that.
`cygpath` ships with Git Bash, so this is a pathological configuration rather than a likely one.

The arm suite's own `test_direct_policy_contract` invokes `node "$POLICY" --root "$ROOT" --home "$ROOT"` directly rather than through the transport, so those cases still hand the policy a converted `--root` on Windows.
No case there embeds an absolute path in its command, so none is affected today, but a future one that did would fail on Windows for a reason that is not the product's.

`tests/fm-turnend-guard.test.sh` and `tests/fm-x-mode.test.sh` open-code the same fakebin loop at three more sites.
They are slice 6's, and `fm_fakebin_link` is what they need.

## Phase B slice 5: the Windows CI lane

`.github/workflows/windows-port.yml` runs `bin/fm-lint.sh` and both portable parallel shards on `windows-latest` under Git Bash, triggered on push to `windows` and on `workflow_dispatch`.
It is expected to be red while the port lands.
Its job is to publish a reproducible count on a clean runner instead of on this one box, so a reviewer can see the same numbers this file claims.

### Two defects stood between the lane and its first run

**Row 19: the lint toolchain would not install at all.**
`bin/fm-install-shellcheck.sh` and `bin/fm-install-actionlint.sh` die with `unsupported platform MINGW64_NT-10.0-26200-x86_64`, so a Windows lint job had nothing to run.
Both projects publish an official Windows asset with a published digest, so each installer gained exactly one `MINGW*|MSYS*` case arm carrying the same `ARCHIVE` + `SHA256` shape the other four arms use:

| Installer | Windows archive | Digest source |
| --- | --- | --- |
| `fm-install-shellcheck.sh` | `shellcheck-v0.11.0.zip` | the release asset's own `digest` field (`gh api repos/koalaman/shellcheck/releases/tags/v0.11.0`) |
| `fm-install-actionlint.sh` | `actionlint_1.7.12_windows_amd64.zip` | `actionlint_1.7.12_checksums.txt`, the same file the four existing pins came from |

Both archives are zips holding one `.exe` at the root, and the GNU tar a Git Bash host provides cannot read a zip, so the extraction step became a two-arm `case` on the archive suffix.
The POSIX arm is the byte-identical `tar -xJf` / `tar -xzf` call each script has always made; `unzip` ships with Git for Windows at `C:\Program Files\Git\usr\bin\unzip.exe`, and its absence is a named `die` rather than a bare 127.
Only `shellcheck` and `actionlint` gained an arm: herdr installs through its own `install.ps1` on Windows and treehouse publishes no Windows asset to pin, so those two keep failing closed on the exact message they had.

**Every checksum verification failed under a Windows `RUNNER_TEMP`.**
This is the finding worth carrying upstream, because it has nothing to do with the new arms and would have bitten any Windows lane:

```
$ RUNNER_TEMP='C:\Users\ebatt\AppData\Local\Temp\fm-slice5' bin/fm-install-shellcheck.sh "$RUNNER_TEMP/bin"
fm-install-shellcheck.sh: checksum mismatch for shellcheck-v0.11.0.zip
  (expected 8a4e35ab...740e, got \8a4e35ab...740e)
```

The digest is correct; it arrives with a leading backslash.
GNU coreutils escapes a checksum line whose file operand contains a backslash or a newline, and marks it by prefixing the whole line with one more:

```
$ sha256sum 'C:\Users\ebatt\AppData\Local\Temp\fm-slice5\f'
\98ea6e4f...be4 *C:\\Users\\ebatt\\AppData\\Local\\Temp\\fm-slice5\\f
$ sha256sum <'C:\Users\ebatt\AppData\Local\Temp\fm-slice5\f'
98ea6e4f...be4 *-
```

`RUNNER_TEMP` on a GitHub Actions Windows runner is always a native path (`D:\a\_temp`), so `awk '{print $1}'` always read a digest with a leading `\` and the pin never matched.
The fix is one redirection in each of the four installers - hash the archive on **stdin**, which keeps the file name out of the output entirely and cannot be escaped by any path shape.
It is not a Windows branch: a POSIX path containing a backslash breaks the old form identically today, so this is a portability fix that happens to have been found on Windows.

The other ~15 `shasum -a 256 "$file" | awk '{print $1}'` sites in `bin/` are left alone.
They hash paths built from `$FM_HOME` and friends, which are POSIX-form on every host firstmate runs on; the four installers are the only scripts that take their temp root from a caller-supplied environment variable that a Windows CI runner fills with backslashes.

### The lane's own shape

- **Serial by construction.** No `--jobs`. `--jobs N` with `N>1` fails every script in the lane, because the runner's own per-worker isolation check requires mode 0700 and reads back 755 on a noacl mount (row 21). The workflow says so in a comment so nobody "optimizes" it back.
- **`--per-script-timeout-secs 300`**, matching how both lanes were measured locally. A process spawn costs roughly ten times what it does on Linux, and the default bound reads a slow-but-healthy script as a hang.
- **`timeout-minutes: 60` on the lint job.** The first draft said 20, which would have made the job fail on the clock for a reason that is not the port. `CI=true bin/fm-lint.sh` was still running healthily 25 minutes in on this box, and the cost is not the usual spawn tax: `fm-lint.sh` hands ShellCheck the whole file set in a few large batches under `--external-sources`, and one batch of ~70 `bin/*.sh` files alone was still going after seventeen minutes. CI also refuses `--fast`, so the full extended analysis is mandatory there. `ci.yml`'s Linux lint job needs no cap at all. Both bounds in this workflow are hang tripwires rather than expected durations, the way `docs/fm-test-portable-shards.md` describes.
- **`MSYS: winsymlinks:nativestrict`** at workflow level. Without it the harness's fakebin construction fails with `ln: failed to create symbolic link`, which was measured in "Portable lane results" above.
- **`cygpath -w` into `GITHUB_PATH`.** `$RUNNER_TEMP/bin` is a mixed path (`D:\a\_temp/bin`); Git Bash reads it fine, and `GITHUB_PATH` gets the unambiguous Windows spelling.
- **A toolchain diagnostic step** prints `uname -srm`, the bash version, and the resolved path of `jq`, `node`, `git`, `curl`, `unzip`, `shellcheck` and `actionlint`, so a missing runner tool reads as a named gap in the log rather than as a mystery failure inside an unrelated test script.
- **`FM_TEST_SUMMARY` into `$GITHUB_STEP_SUMMARY`**, so the count to beat is on the run page rather than buried in the log, and the whole `fm-test/` directory is uploaded on `always()`.

### `tests/fm-lint.test.sh` was red for the fakebin reason, not row 19

Phase A classified `fm-lint`'s failure as "test: exercises `fm-install-shellcheck.sh`, which dies on `uname` (row 19) before the fallback".
That was wrong: the test stubs `uname`, so it never reaches the platform switch.
The real cause is slice 4's finding, at the two sites this file open-codes:

```
$ PATH="$fakebin" "$fakebin/bash" -c 'mktemp -d /tmp/probe.XXXXXX'
.../fakebin/bash: error while loading shared libraries: ?: cannot open shared object file
rc=127
```

Windows resolves an MSYS executable's DLLs against the directory the image was launched from and then against `PATH`, so a symlinked `bash.exe` in a fakebin holding no `msys-2.0.dll` dies before the script under test runs a line.
`fm_fakebin_link` (added in slice 4) is exactly the fix, and the four remaining open-coded loops in this family - two in `tests/fm-lint.test.sh`, two in `tests/fm-lint-workflows.test.sh` - now use it.
`tests/fm-turnend-guard.test.sh`, `tests/fm-x-mode.test.sh`, `tests/fm-bearings-snapshot.test.sh` and `tests/fm-kimi-harness.test.sh` still open-code it; they are slice 6's.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-install-shellcheck.sh "$RUNNER_TEMP/bin"` with `RUNNER_TEMP` a native Windows path | installs `shellcheck.exe`, prints `version: 0.11.0` |
| `bin/fm-install-actionlint.sh "$RUNNER_TEMP/bin"` likewise | installs `actionlint.exe`, prints `1.7.12 ... for windows/amd64` |
| `bin/fm-lint-workflows.sh` (actionlint 1.7.12, pinned) | `4 workflow files valid` |
| `command -v shellcheck` against the installed `shellcheck.exe`, then executing what it returns | resolves to the extensionless path, MSYS appends `.exe` on exec, `--version` parses as `0.11.0` and a real file is analyzed - so `bin/fm-lint.sh`'s own resolution chain (`command -v` into `SHELLCHECK_BIN`) needs no Windows branch |
| `bin/fm-lint.sh` on the six changed shell files, by explicit path | clean (ShellCheck 0.11.0, full extended analysis) |
| `tests/fm-lint.test.sh` | **28 / 28 on Windows** - was red at case 11 |
| `tests/fm-lint-workflows.test.sh` | **17 / 17 on Windows** |
| `bin/fm-test-run.sh --check-coverage` | `ok total=170 parallel=24 serial=134 serial_shards=4 herdr=12` |
| Mutation: hash by name again in `fm-install-shellcheck.sh` | the backslash-temp-root case fails, showing `got \8c3be12b...` - the production defect itself |
| Mutation: flip one hex digit of the Windows pin in `fm-install-actionlint.sh` | `installer failed for MINGW64_NT-10.0-26200/x86_64` |
| Mutation: `elif command -v shasum` to `elif false` | `installer did not fall back to shasum -a 256`, so the `fm_fakebin_link` PATH really exercises the fallback |
| Mutation: unzip an archive the installer never downloaded | `installer failed for MINGW64_NT-10.0-26200/x86_64` |

Both suites' new coverage runs on any host, the way slices 1-4's does.
The platform table gained a `MINGW64_NT-*` and an `MSYS_NT-*` row plus a fifth column for the expected binary name, driven by a stub `unzip`; the new backslash case creates a real directory whose name contains a backslash and points `RUNNER_TEMP` at it, and the stub hasher now reproduces coreutils' escaping exactly, so the case fails on Linux too if the redirection is reverted.

### What the acceptance review changed

The adversarial review's central question was whether hashing on stdin weakens the supply-chain check.
It does not, and the argument is worth keeping: the redirection is an `O_RDONLY` open by the shell of the identical path the extraction step opens later, so the hash-then-extract window is byte-for-byte what it always was, and the archive still sits in a fresh `mktemp -d` 0700 directory either way.
The reviewer measured the stdin form on GNU coreutils 8.32 here, perl `shasum -a 256`, Linux GNU and BusyBox: all four print the digest in field 1 with no file name at all, so no path shape can shift what `awk` selects.
It is the *by-name* form that varies by input, which makes the change equal-or-stronger rather than a trade.
It also reproduced both pins independently from the release API and the checksums file, and confirmed both `.exe` files sit at their zip roots.

Two findings became changes:

- **`python3` was missing from the toolchain probe** while `--json` hard-dies without it (`bin/fm-test-run.sh:1372`). It resolves on `windows-latest` today, but if that ever changed the failure would read as a mystery inside the test runner rather than a named gap. It is now in the probe list.
- **The stub `unzip` ignored its archive operand**, so a mutation that extracted the wrong file still produced a working install and passed. It now refuses an archive that does not exist, and that mutation fails.

Three findings are recorded rather than fixed: an interleaving risk in the `grep '^FM_TEST_SUMMARY '` step whose only consequence is the fallback line it already prints; the `set -uo pipefail` line implying `-e` was meant to be off when GitHub already passes it (the `| tee ... || rc=$?` pattern is correct either way); and a process note for anyone repeating this review.
That note is worth stating plainly: `git checkout --` is the wrong restore mechanism against an uncommitted slice, because it restores to `HEAD` and so destroys the very thing under review.
It did exactly that here, mid-review, and the recovery was from saved copies.
Every file in this slice was afterwards compared byte-for-byte against a snapshot taken before the review started, and every one matched.

### Not fixed here

The bootstrap hint still prints `brew install` on Windows, which is the cosmetic half of row 19.

`fm-install-herdr.sh` and `fm-install-treehouse.sh` still die on a Windows userland.
They got the stdin fix because the defect was identical and two lines away, but neither has a Windows asset to pin, and herdr's own `install.ps1` is what `windows-herdr-spike.yml` already uses.

The lane cannot be exercised from this branch: `workflow_dispatch` needs the workflow present on a branch GitHub will offer, and the push trigger is scoped to `windows`.
Its first real count comes from the fork's `windows` branch.

The lane runs the two parallel shards only, so it covers `tests/fm-lint.test.sh` but not `tests/fm-lint-workflows.test.sh`, which lives in the portable serial lane.
Both were run here by hand for this slice; a Windows serial lane is slice 6's question, once its runtime is known.

## Phase B slice 6: triaging the parallel lanes' remaining reds

Measured 2026-08-29, same machine and toolchain as Phase A.
Phase A left 12 red scripts across the two portable-parallel lanes with a provisional class for each.
Slices 4 and 5 closed three of them.
This section settles the remaining nine, with a measured cause rather than a guess, and fixes what turned out to be product.

One Phase A verdict was wrong and is corrected in place above: `fm-backend-herdr` was marked "resolved in slice 3", but slice 3's own verification section says the opposite ("fails at the identical assertion as Phase A, 19 cases in"). It is still red, and its cause is settled below.

### Verdicts

| Script | Phase A note | Measured cause | Class |
| --- | --- | --- | --- |
| `fm-composer-lib` | "text-width or locale handling of block glyphs" | Git Bash's bash does not expand `\uHHHH` unless `LANG`/`LC_ALL` names a UTF-8 locale, and Git Bash starts with `LANG` empty. The fixture's `printf '\u2580'` produced the six literal characters `\u2580`, so `fm_composer_row_has_edge` was asked about a row that had no half-block glyph in it. | **test** - fixed |
| `fm-ensure-agents-md` | "the one test that wants CRLF kept" | Real defect: `LC_ALL=C grep -q $'\r$'` answers *no* for every CRLF file on Git for Windows, so the self-governance section was appended LF-terminated into a CRLF file. | **product** - fixed |
| `fm-crew-state` | "timing or `ps`-based liveness (row 2)" | Neither: `make_no_timeout_toolbin` symlinked nine MSYS binaries into a directory that then became the child's whole `PATH`, and a symlinked MSYS binary cannot load `msys-2.0.dll`. Slice 4's finding, at one of the four sites it left. | **test** - fixed |
| `fm-herdr-lab` | "test/timing under slow spawn" | The fixture held the fake server for 30 s and assumed the 300-attempt provisioning poll finishes long before that; each attempt spawns a `herdr` and a `jq`, so on this box the loop outlasted the delay and the "late" launch arrived first. Removing the timing assumption then exposed a real cross-platform bug underneath it: `fm_herdr_lab_cancel_provision` never cancelled anything. | **test** + **product** - both fixed |
| `fm-backend-herdr` | "resolved in slice 3" (wrong) | Never fixed. A native `jq.exe` writes CRLF, so a MULTI-row read carries an interior CR: `matches` is `w1\r\nw7`, and `${matches//$'\n'/ }` makes the refusal say `w1\r w7`, which looks right on a terminal and does not match. | **product** - not fixed here |
| `fm-captain-hold-lifecycle` | "hang once symlinks are real, investigate with `bash -x`" | Not a hang and not symlinks. Two independent things: the script needs ~700 s here (17 cases, ~60 s each) so the 300 s per-script bound killed it mid-run, and `fm-procevent.sh start` died on `ps -o pgid=`. | **product** (the pgid read) + **platform** (spawn cost) - fixed / documented |
| `fm-pr-merge` | "unknown (fake `gh` fixture)" | Nothing to do with `gh`. `fm-pr-check.sh` refuses with `error: could not prepare PR poll` because `fm_pr_private_file_valid "$tmp" 600` can never hold where `chmod 0600` reads back 644. | **platform: row 21**, and the one that blocks Phase C |
| `fm-x-mode` | "platform: row 21" | Confirmed unchanged (`state/` at mode 700). | **platform: row 21** |
| `fm-test-run` | "platform: row 21" | Confirmed unchanged (the runner's own `--jobs` worker-root isolation check). | **platform: row 21** |

### `grep`, `sed` and `awk` on Git for Windows silently drop a trailing CR

`bin/fm-ensure-agents-md.sh` keeps an existing AGENTS.md's line endings when it injects its self-governance section, and decides which they are with one probe:

```sh
if LC_ALL=C grep -q $'\r$' "$AGENTS"; then eol=$'\r\n'; fi
```

That probe is always false here.
Git for Windows patches GNU grep (3.0), sed and awk to strip a trailing CR before matching, and the mounts are all `binary`, so it is the tools and not the mount:

```
$ printf 'a\r\nb\r\n' > t.txt && od -c t.txt | head -1
0000000   a  \r  \n   b  \r  \n
$ LC_ALL=C grep -q $'\r$' t.txt; echo $?          # 1
$ LC_ALL=C grep -q $'\r'  t.txt; echo $?          # 1  (anywhere, not just anchored)
$ LC_ALL=C grep -q $'\r$' < t.txt; echo $?        # 1  (stdin too)
$ LC_ALL=C awk '/\r$/{f=1} END{exit !f}' t.txt; echo $?   # 1
$ LC_ALL=C sed -n '/\r$/p' t.txt | wc -c          # 0
$ tr -dc '\r' < t.txt | od -c | head -1           # \r      - tr is binary-safe
$ IFS= read -r l < t.txt; printf '%s' "$l" | od -c | head -1   # a \r  - bash read keeps it
```

So a Windows user's CRLF AGENTS.md came back with an LF-terminated section stitched onto the end of it - a mixed-line-ending file that every subsequent diff shows as noise.

The fix replaces the probe with a `file_uses_crlf` helper built out of bash's own `read`, which strips the newline and nothing else on every platform.
`grep -U` would also have worked on MSYS, but `-U` means something different in BSD grep, so it is not a portable spelling.
This is not a Windows branch: it is one answer everywhere, and on macOS and Linux it answers exactly what the `grep` did.

The blast radius was checked rather than assumed. Every other CR test in `bin/` is a bash `case` on a variable (`*$'\r'*`), which bash evaluates itself; `bin/fm-ensure-agents-md.sh:75` was the only one that asked a text tool.
`bin/fm-branch-outcome.sh:68`'s `gsub(/\r/, "\\r", line)` is a display escape whose input arrives CR-free on Windows, so it is a no-op there rather than a defect.

### MSYS `ps` has no `-o pgid=` either, in three more callers

Slice 1 gave `bin/fm-proc-lib.sh` `comm`, `args`, `ppid`, `chain` and `pid_alive`, and wired the four callers that used them.
It missed `pgid`, which four call sites read the same broken way. What each one did on Windows:

| Site | Windows behavior before |
| --- | --- |
| `bin/fm-procevent.sh:339` (`require_runner_group`) | `pgid` empty, so `fm-procevent.sh start <source>` **always** died with `error: cannot inspect runner process group`. Every captured-result channel - lavish, remote-reply, the captain-hold answer intake - was dead on this platform. |
| `bin/fm-procevent.sh:678` (`stop_runner_pid`) | returns 2, so a live runner could never be stopped by group. |
| `bin/fm-watch.sh:933` | `pgid` empty, so the `[ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]` guard is skipped and the watcher's proof that its check subshell leads its own group never ran. |
| `bin/fm-sessionstart-nudge.sh:33` | the ancestry walk stopped at its first hop, so `lock_is_in_ancestry` was false for every session and the SessionStart nudge fired at a primary that had already run `fm-session-start.sh`. |

MSYS publishes the answer as a file, in the same `/proc/<pid>/` directory `fm_proc_comm` and `fm_proc_ppid` already read, so the new `fm_proc_pgid` costs no process at all there and is literally `ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'` everywhere else:

```
$ ps -o pgid= -p $$          # ps: unknown option -- o
$ cat /proc/$$/pgid          # 13823, and $$ is 13823
```

`bin/fm-sessionstart-nudge.sh` also had a second Windows defect in the same four lines: its `kill -0 "$lock_pid"` liveness probe. Slice 1 made the session lock record the harness's **Win32** pid on a Windows userland, and `kill -0` reports a Win32 pid as absent. Both now go through the library, and the walk gets the `fm_proc_chain_prime` call every other caller has, so an MSYS-to-Win32 ancestry costs one pwsh process instead of one per hop.

`bin/fm-teardown.sh`'s three `ps -o pgid=` reads and `bin/fm-remote-entrypoint.sh`'s two `ps -o ppid=` reads are deliberately untouched: the first is inside a tmux-only `lsof`-unavailable fallback that fails safe (it prints a warning and returns 0) and is unreachable on a herdr backend, and the second runs on the remote host, which is never Windows. Both are named here so the next sweep does not have to rediscover them.

### `\uHHHH` in a test fixture depends on the ambient locale

Git Bash starts with `LANG` empty, and bash's `\uHHHH` expansion - in `$'...'`, in `printf`, and in `printf %b` - falls back to emitting the escape literally when the locale's charset is not UTF-8:

```
$ echo $LANG            # (empty)
$ x=$'\u2580\u2580'; printf '%s' "$x" | od -c | head -1
0000000   \   u   2   5   8   0   \   u   2   5   8   0
$ LANG=C.UTF-8 LC_ALL=C.UTF-8 bash -c 'printf "%s" $'"'"'\u2580'"'"'' | od -c | head -1
0000000 342 226 200
```

`tests/fm-composer-lib.test.sh` built its herdr half-block rule fixture that way, so on this host it asserted that a row containing the ASCII text `\u2580\u2580\u2580` is a structural edge - which it is not, and should not be.
The fixture now uses the literal UTF-8 glyphs, which is what `bin/fm-composer-lib.sh`'s own `case` patterns have always used, and what the rest of this same test file already used for `❯`, `›`, `⟩` and `→`.
On a UTF-8 host the bytes are identical; on a host without a locale the test now tests what it says it tests.
This is not Windows-specific - a Linux container with no `LANG` behaves the same way - so it is a portability fix rather than a platform branch.

Four other test files still carry shell `\uHHHH` escapes (`fm-afk-pi-herdr-return-e2e`, `fm-calm-pi-extension`, `fm-pi-watch-extension`, `fm-turnend-guard`). All four are in the portable **serial** lane, so they are triaged with that lane rather than guessed at here.

### The herdr-lab fixture raced its own poll loop, and hid a real bug when it did

`test_timed_out_provision_cancels_late_launch` claims to prove that a provisioning attempt which times out cancels the background `herdr server` it started.
It expressed "the server never becomes ready" as a 30-second delay, which is a fact about wall time and not about the loop - and `fm_herdr_lab_provision` polls 300 times, spawning a `herdr` and a `jq` each time, so here the server won the race and provisioning returned 0.

Raising the delay would only have moved the race. The fake now records its own pid and holds for ten minutes without ever reporting ready, and the test asserts that **that pid is not alive** after teardown. There is no timing left in the assertion at all.

That is what turned up the real defect. `fm_herdr_lab_provision` launched the server as `fm_herdr_lab_raw "$name" server &` and cancelled it by TERMing `$!`. Bash exec-optimizes a backgrounded simple command and a backgrounded subshell, but **never a backgrounded function call**, so `$!` was a wrapper shell and `herdr` was its child:

```
$ f() { local n=$1; shift; HERDR_SESSION="$n" /usr/bin/sleep 30 "$@"; }
$ f x >/dev/null 2>&1 & p=$!
$ ps -f | awk -v p="$p" '$3==p {print "CHILD:", $2, $NF}'
CHILD: 22683 /usr/bin/sleep
$ kill -TERM "$p"; ps -f | awk '{print $2, $3, $NF}' | grep sleep
22683 1 /usr/bin/sleep          # reparented to init, still running
```

So a timed-out lab provision left its `herdr server` running, on every platform, since the function was written. The fix is a `fm_herdr_lab_raw_exec` sibling used only for that one backgrounded launch: `exec` makes the background job's pid the server's own pid, which is the pid the canceller always assumed it had. This is the one place in the slice where macOS and Linux behavior changes, and it changes from "leaks the server" to "kills it".

The rewritten test is the proof: green with `fm_herdr_lab_raw_exec`, and `timed-out provision left its lab server running after teardown (pid 42481)` the moment it is mutated back to `fm_herdr_lab_raw`. The earlier gate-file version of this fixture passed on Windows either way - its orphan's bounded wait expired during the slow poll loop - which is exactly the kind of pass this rewrite removes.

### `fm-backend-herdr` is still red, and the reason is the jq CRLF finding again

Phase A's table said "resolved in slice 3". It was not: slice 3's own "Not fixed here" paragraph says the assertion fails unchanged and hands it to this triage. The cause is now settled.

`bin/backends/herdr.sh:1698` reads a MULTI-row jq answer:

```sh
matches=$(printf '%s' "$list" | jq -r --arg want "$label" \
  '.result.workspaces[]? | select(.label == $want) | .workspace_id')
```

Bash's command substitution strips the trailing `\r\n` on MSYS, so a single-value read is clean - which is why almost everything in the adapter works. A two-row answer keeps its **interior** CR, so `matches` is `w1\r\nw7`, and `${matches//$'\n'/ }` renders the refusal as `w1\r w7`. On a terminal that prints as `w1 w7`, which is exactly why Phase A recorded "yet the captured stderr names `(w1 w7)`".

This is the same defect class slice 4 fixed in the hook transport with `fm_hook_payload_string`, and it is a product defect rather than a test one: any operator reading that refusal gets a control character in the middle of the workspace list they are being asked to act on.

It is **not fixed here**. The adapter has 62 `jq -r` reads, of which nine produce multiple rows, and several feed `while read` loops where each line would carry its own CR; the right shape is one `fm_backend_herdr_jq` funnel with those nine sites moved onto it, verified against the 60-plus-case `tests/fm-backend-herdr.test.sh`. That is a PR-3 follow-up slice, not part of this triage, and it is named here with its site list so it does not have to be rediscovered.

### New finding: node's `spawn()` cannot execute a shebang script on Windows

Fixing the nudge's ancestry walk took `tests/fm-sessionstart-nudge.test.sh` from red at case 7 to red at case 8, which exposed a second, unrelated Windows defect:

```
Error: spawn EFTYPE
    at ChildProcess.spawn (node:internal/child_process:458:11)
    at .opencode/plugins/fm-primary-sessionstart-nudge.js:9:19
```

Windows `CreateProcess` cannot run a `.sh` file, and `spawn()` reports that by **throwing synchronously**, which the plugin's `child.on("error", ...)` handler never sees - so the failure is not the documented silent one, it is an exception out of an OpenCode event hook.
All five `.opencode/plugins/*.js` spawn a firstmate `.sh` through the same shape, so the whole OpenCode adapter is affected, not this one plugin.
It is recorded rather than fixed here: the fix is one shape repeated five times plus five plugin suites to re-run, it is a different adapter from the one Phase C uses, and it belongs with the serial lane's triage.

### Row 21 reaches Phase C through `fm-pr-merge`

`fm-pr-merge` was Phase A's "unknown (fake `gh` fixture)". It is row 21, and it is the site that matters most:

```
$ : > f && chmod 0600 f && stat -c '%a' f
644
```

`fm_pr_poll_prepare` (`bin/fm-pr-lib.sh:490`) validates its own freshly-`chmod 0600` temp file with `fm_pr_private_file_valid "$FM_PR_POLL_DATA_TMP" 600 ...`, which cannot hold on a `noacl` mount, so `bin/fm-pr-check.sh:99` prints `error: could not prepare PR poll` and exits 1 before any merge outcome is read.
`tests/fm-procevent.test.sh` reaches the same wall one assertion later (`the captured result is private (missing: '600')`).

Phase C's ship task ends in a crewmate delivering a PR and the captain saying "merge it", and that path runs straight through `fm_pr_poll_prepare`.
This is the concrete D6 trigger the plan reserved: it is a mode check outside the herdr adapter that blocks Phase C, so the minimal `noacl` relaxation belongs at this site, modelled on `fm_backend_herdr_presentation_lock_namespace_valid`'s probe. It is not implemented in this slice, which is triage plus the product defects triage found; it is the first thing Phase C does.

### Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on all 15 changed shell files, by explicit path | clean (ShellCheck 0.11.0, full extended analysis) |
| `bin/fm-lint-workflows.sh` | `4 workflow files valid` (actionlint 1.7.12, pinned) |
| `bin/fm-test-run.sh --check-coverage` | `ok total=170 parallel=24 serial=134 serial_shards=4 herdr=12` |
| `tests/fm-proc-lib.test.sh` | **15 / 15** (was 13; two new cases for `fm_proc_pgid`) |
| `tests/fm-ensure-agents-md.test.sh` | **green** - was red on the CRLF injection case |
| `tests/fm-composer-lib.test.sh` | **green** - was red on the half-block edge case |
| `tests/fm-crew-state.test.sh` | **green** - was red on the no-timeout perl-bound case |
| `tests/fm-herdr-lab.test.sh` | **7 / 7** - was red on the timed-out-provision case |
| `tests/fm-captain-hold-lifecycle.test.sh` | **17 / 17 in 1091 s** - was killed by the 300 s bound after 5 cases, then red on `fm-procevent.sh start` |
| `tests/fm-procevent.test.sh` | 1 case before the first failure at `HEAD`, **9** with this slice; the remaining red is the row-21 mode-600 assertion |
| `tests/fm-sessionstart-nudge.test.sh` | red at case 7 (`owned lock nudge must be silent`) at `HEAD`, red at case 8 (the node `spawn` EFTYPE finding) with this slice |
| `tests/fm-watcher-lock.test.sh` | 10 cases then `expected exactly one lock winner under concurrency, got 2` - **byte-identical at `HEAD`**, so not a regression |
| Mutation: drop `| tr -d '[:space:]'` from the POSIX `fm_proc_pgid` | `posix fm_proc_pgid returned ' 600  '` |
| Mutation: accept a non-numeric `/proc/<pid>/pgid` | `a non-numeric pgid file must make fm_proc_pgid fail` |
| Mutation: force the MSYS branch through `ps` | `the MSYS pgid read must run no ps` |
| Mutation: read `/proc/<pid>/ppid` instead of `/pgid` | `msys fm_proc_pgid returned '601', expected /proc/600/pgid` |
| Mutation: `return 1` on the MSYS success path | `msys fm_proc_pgid must exit 0 when it answers` |
| Mutation: `return 1` on the POSIX success path | `posix fm_proc_pgid must exit 0 when it answers` |
| Mutation: `fm_herdr_lab_raw_exec` back to `fm_herdr_lab_raw` | `timed-out provision left its lab server running after teardown (pid 42481)` |

### The lane counts

Both lanes re-run end to end on this machine with `MSYS=winsymlinks:nativestrict` and `--per-script-timeout-secs 1500`:

| Lane | Phase A | Now |
| --- | --- | --- |
| portable-parallel-1 | 5 green / 5 red / 1 gate-skip of 11 (903 s) | **8 green / 2 red / 1 gate-skip of 11 (2570 s)** |
| portable-parallel-2 | 6 green / 7 red of 13 (670 s) | **11 green / 2 red of 13 (1805 s)** |
| both | 11 green / 12 red / 1 gate-skip of 24 | **19 green / 4 red / 1 gate-skip of 24** |

The four remaining reds are `fm-x-mode`, `fm-test-run` and `fm-pr-merge` (all row 21, all waiting on D6) and `fm-backend-herdr` (the jq CRLF defect above).

The wall time roughly tripled because the whole lane now RUNS instead of dying early: `fm-captain-hold-lifecycle` alone contributes 1091 s and `fm-arm-pretool-check` 748 s, both of which used to stop in seconds. Two consequences for the Windows CI lane, both applied: its per-script bound goes from 300 s to 1500 s (two scripts already exceed 300 s), and `timeout-minutes` goes from 60 to 120, which was the real constraint.

### What the acceptance review changed

The adversarial review cleared the two questions that mattered most and then broke the slice open on a third.

It cleared the **security question** with an argument rather than an assertion: every new failure mode of `fm_proc_pgid` on MSYS fails closed. The digits-only guard rejects a CR, whitespace, multiple fields and garbage, so `stop_runner_pid` can never be handed a group that is not the one it validated; an unreadable or racing `/proc` entry yields a non-zero status, which each caller already treats as "do not signal". It also settled the **exit-status** question at all four sites: the old `ps ... | tr` pipeline always exited 0 (tr's status), so the `|| die` and `|| return 2` arms beside it were dead code on every platform, and they stay dead on POSIX because the numeric guard is unreachable there. On MSYS they newly fire, always in the refusing direction. The only POSIX cost of the whole slice is one `uname -s` fork per script that gained the library.

It returned two surviving mutations in the new tests, both now dead:

- The fake `/proc` gave pid 600 the same value for `ppid` and `pgid`, so reading `/proc/<pid>/ppid` instead of `/pgid` passed everything. 600 now leads its own group, and that mutation fails.
- Neither new case asserted the SUCCESS exit status - only the refusals - so `return 0` mutated to `return 1` passed while every caller would have died. Both branches now assert it, and both mutations fail.

And it found the herdr-lab cancellation bug described above, by measuring bash's exec optimization for all three background shapes rather than assuming. That finding is why this slice contains a cross-platform behavior change at all.

Three smaller findings became changes: four other test files copy `bin/fm-sessionstart-nudge.sh` into a fixture without its new library dependency (`fm-calm-pi-extension`, `fm-cursor-primary`, `fm-opencode-primary-live-e2e`, `fm-pi-primary-live-e2e` - two of them execute the nudge path); the `/proc/<pid>/pgid` comment claimed the file carries no trailing newline, which is true of `exename` beside it but not of `pgid`, `ppid` or `winpid` here; and the Windows lane's `timeout-minutes: 60` is now the binding constraint rather than the per-script bound.

Two are recorded rather than fixed: `tests/fm-procevent.test.sh:196` and `tests/fm-home-summary-refresh.test.sh:266,271` read `ps -o pgid=` directly in TEST code and become the next red the moment row 21's D6 relaxation lands, and an empty `/proc/<pid>/pgid` file has no fixture (the `''` arm of the guard survives mutation, though every caller tolerates empty output).

### Not fixed here

`fm-x-mode`, `fm-test-run` and `fm-pr-merge` stay red: all three are row 21, and the D6 decision that unblocks them is Phase C's first move, not this slice's.

The five `.opencode/plugins/*.js` cannot spawn a firstmate `.sh` on Windows (the EFTYPE finding above). `tests/fm-sessionstart-nudge.test.sh` therefore stays red one case later than it was.

`tests/fm-watcher-lock.test.sh` fails `expected exactly one lock winner under concurrency, got 2` on this host - byte-for-byte the same failure at `HEAD` as with this slice applied, so it is a pre-existing Windows red rather than a regression. It lives in the portable serial lane and is triaged with it. It is worth flagging as a lead: it is the watcher SINGLETON lock, so if it is a real defect rather than a fixture assumption it matters more than its lane suggests.

Four test files still build fixtures out of shell `\uHHHH` escapes and will have the composer-lib problem on any host with no `LANG`. All four are in the portable serial lane.

`bin/fm-teardown.sh` and `bin/fm-remote-entrypoint.sh` still read `ps -o` directly, for the reasons given above.

`tests/fm-cursor-primary.test.sh` (run here because it copies `bin/fm-sessionstart-nudge.sh` into a fixture) stops on its first case with `a C compiler is required to build the fake Cursor process`. Git for Windows ships no `cc`, so that is a toolchain gap in the serial lane rather than anything this slice touched, and it means the copy-list change above is verified by lint and by inspection there rather than by a run.

The portable serial lane (134 scripts) has still not been run end to end here. It is the next unit of work, and it now has a measured per-script budget to plan against: `tests/fm-captain-hold-lifecycle.test.sh` alone needs 1091 s.

## Phase B slice 7: splitting the integration branch into four upstream branches

Phase B's six slices are six commits on one integration branch, and no upstream reviewer would want them in that shape.
This slice cuts the four branches the plan scoped - `pr-1-gitattributes`, `pr-2-proc-lib`, `pr-3-herdr-windows-cli`, `pr-4-herdr-windows-pane` - from `upstream/main` at `f66be0f`, verifies each one on its own on this machine, and pushes them to the fork only.
The full map, including what each branch carries and what is deliberately held back, is in [prs.md](prs.md); this section records how the split was verified and the two things that turned out not to be mechanical.

### The split is not a straight cherry-pick, in two places

`pr-2-proc-lib` cannot be one cherry-pick, because the process library was built in slice 1 and extended in slice 6, and slice 6's commit also carries the CRLF fix, the herdr-lab fix and three test-fixture fixes that belong nowhere near it.
Cherry-picking the whole of `0865847` into a branch named for the process library would have been the easy answer and the wrong one.

What makes the path-scoped alternative exact rather than a shortcut is a property that had to be checked, not assumed:

```
$ git log --oneline upstream/main..0865847 -- bin/fm-proc-lib.sh
0865847 9286fe7
$ git log --oneline upstream/main..0865847 -- bin/fm-procevent.sh
0865847
```

Each of the ten files in `pr-2` is touched by slice 1, or slice 6, or both, and by no other slice.
So the file's content at `0865847` **is** the whole of the process-library work on it, and `git checkout 0865847 -- <those ten paths>` reproduces it byte for byte.
The same query is what proves `bin/backends/herdr.sh` belongs to slices 2 and 3 only, and `tests/lib.sh` to slice 4 only.

`pr-4-herdr-windows-pane` is stacked on `pr-3` rather than cut from `upstream/main`.
Both change `bin/backends/herdr.sh` and `tests/fm-backend-herdr-windows.test.sh`; the pane work reads as a diff against the CLI work and would conflict against bare upstream.
That is a property of the code, not of the split, and it is the one ordering constraint among the four.

Cherry-picking each slice commit onto a branch without `docs/windows/` produces exactly two conflicts every time - `modify/delete` on `measurement.md` and `plan.html` - which is the expected shape and is resolved with `git rm`.
No conflict ever appeared in `bin/` or `tests/`.

### Nothing was lost and nothing drifted

Two checks, both mechanical, both run over every path:

The first compares each file on its branch against the integration branch, `git diff <branch>:<path> 0865847:<path>`.
The four branches touch twenty distinct paths; nineteen are byte-identical at the branch that finally carries them, and the twentieth, `bin/fm-test-run.sh`, is byte-identical on **no** branch and cannot be - each branch carries only its own registration line, while the integration copy also registers the guard test from slice 4.
For that file the property that holds instead is that each branch's diff against `upstream/main` is a strict subset of the integration diff, and `--check-coverage` passes on each branch.

That correction came out of the acceptance review, and its cause is worth recording: the first version of this check iterated a path list written by hand, which silently omitted `bin/fm-test-run.sh` and then reported `fail=0`.
A verification loop whose input is typed rather than derived proves whatever it was given.

The second is the inverse and is the one that would catch an omission: every path in `git diff --name-only upstream/main 0865847` was resolved to the branch that carries it, or to `INTEGRATION-ONLY`.
Forty-four paths, all accounted for, none unclassified.
The integration-only set is the guard fixes, the CI lane and installers, three cross-platform bug fixes and the port's own documents, each with its reason in [prs.md](prs.md).

One dependency was worth checking rather than assuming: slice 4 added `fm_fakebin_link` to `tests/lib.sh`, and `tests/lib.sh` is integration-only.
None of `pr-2`'s six test files references it, and `pr-3`/`pr-4`'s test file does not either - which their green runs confirm.
Had one of them, the branch would have been green here and red for a reviewer.

### Verification

Each branch was checked out and verified on its own, with no other slice's code present.

| Branch | Check | Result |
| --- | --- | --- |
| all four | cut from `upstream/main` at `f66be0f`, pushed to `origin` only | `pr-1` `0fd5857`, `pr-2` `94ddb42`, `pr-3` `d15d309`, `pr-4` `4937c52` |
| `pr-2-proc-lib` | `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `pr-2-proc-lib` | `shellcheck -x` on all seven changed shell files | clean |
| `pr-2-proc-lib` | `tests/fm-proc-lib.test.sh` | 15 / 15, exit 0 |
| `pr-2-proc-lib` | `tests/fm-sessionstart-nudge.test.sh` | red at case 8, byte-for-byte the documented `spawn()` EFTYPE red, not a split artifact |
| `pr-3-herdr-windows-cli` | `--check-coverage`, `shellcheck -x bin/backends/herdr.sh` | `ok` line, clean |
| `pr-3-herdr-windows-cli` | `tests/fm-backend-herdr-windows.test.sh` | 21 / 21, exit 0 |
| `pr-4-herdr-windows-pane` | `--check-coverage`, `shellcheck -x bin/backends/herdr.sh` | `ok` line, clean |
| `pr-4-herdr-windows-pane` | `tests/fm-backend-herdr-windows.test.sh` | 32 / 32, exit 0 |

`--check-coverage` is the check that would catch the family-map hazard: `bin/fm-test-run.sh` is edited by both `pr-2` and `pr-3`, each registering one new test file, and a branch that registered a test it does not carry (or carried one it does not register) fails there.
Both hunks land in different `case` arms 60 lines apart, so the two branches also do not conflict with each other.

`pr-1-gitattributes` has nothing to run; its effect is the checkout, and it is the precondition for every other branch's shebangs executing at all.

### What the acceptance review changed

The review was given the five claims this slice makes and told to break them.
It verified four in substance - faithful, complete, self-standing, correctly ordered - and broke the fifth, which was the prose rather than the split.

Three findings, all now applied above: the byte-identity overstatement and its cause, the `pr-2` test-file count (six, not four), and the hunk distance (61 lines, not 60).

Three of its confirmations are worth keeping because they were derived independently rather than restated:

- `pr-4` genuinely requires `pr-3`, and it proved it rather than assuming it: `git diff pr-3 pr-4 -- bin/backends/herdr.sh` adds two calls to `fm_backend_herdr_win32_cli`, and `git grep` finds no such symbol at `upstream/main`. The stacking is a code dependency.
- No branch references a slice-4-only helper. It checked both `fm_fakebin_link` and `fm_hook_payload_string`, and separately confirmed that the guard-script lines inside `tests/fm-cursor-primary.test.sh` are pre-existing upstream lines rather than anything `pr-2` adds.
- `* text=auto eol=lf` is safe for this repository specifically: upstream has zero `.bat`, `.cmd`, `.ps1` or `.sln` files, which are the file types that would want CRLF preserved.

### The Phase D bodies are written, not sent

With Phase B frozen, the four PR bodies no longer depend on anything still moving, so they were written in the same pass: `docs/windows/upstream/pr-1.md` through `pr-4.md`.
Each carries the defect it fixes with its live before/after output, the design choice that is worth arguing about, the POSIX-identity argument, the verification table, and the open items a reviewer should be told rather than left to find.
PR-4's body states the stacking requirement in its first three lines, because that is the one thing a maintainer could get wrong by merging in the obvious order.

`docs/windows/upstream/issue.md` is deliberately not written yet.
It is the cover letter, and the most persuasive thing it can say is whether the captain's flow actually runs on this machine, which is Phase C's answer and not yet known.

Nothing has been sent: no issue, no pull request, no push to `upstream`, and the README platform badge is untouched.

### Not fixed here

No pull request was opened and nothing was pushed to `upstream`.
The branches sit on `EvanBatten/firstmate-for-windows` waiting for the captain.

The four branches are also not the whole port.
The guard fixes are the strongest candidate for a fifth PR - three fail-opens in a security seatbelt is a different argument from a portability patch - and the installer checksum fix is portable enough to stand alone as a sixth.
Both are named in [prs.md](prs.md) with the reason they are held rather than bundled.

`tests/fm-backend-herdr.test.sh`'s jq CRLF red is still open inside `pr-3`'s area and is called out in that branch's row in [prs.md](prs.md), so a reviewer meets it as a known follow-up rather than as a surprise.
It can land as an additional commit on the pushed branch; none of the four may be force-pushed.

## Phase C: the captain flow on this machine

Run 2026-08-29 against the live firstmate home at `C:\Users\ebatt\firstmate`, fast-forwarded to `0865847` (Phase B slices 1-6).
Timestamps below are GitHub's, because the machine suspended and resumed partway through and its own clock is not a reliable narrator of this run (that is finding 25).
The primary is a real `claude --dangerously-skip-permissions` session in a herdr tab of the DEFAULT session, steered only through `herdr pane send-text` / `send-keys` and observed only through `herdr pane read`.
Everything below is what actually happened, in order, including the five things that did not work.
The loop itself - order, crewmate, worktree, PR, merge, teardown - ran clean twice; the failures are all in the machinery around it, and each one is a ledger row at the end of this section.

### C0. Preconditions

```sh
git -C C:/Users/ebatt/firstmate fetch origin
git -C C:/Users/ebatt/firstmate merge --ff-only origin/gnhf/objective-finish-the-589b84
#   Updating 4f38fc5..0865847 - Fast-forward, 42 files changed, 3898 insertions(+), 216 deletions(-)
```

The home is left on `windows`, clean, and nothing is ever pushed from it.

The sandbox project is a new private repository, created for this and used for nothing else:

```sh
gh repo create EvanBatten/fm-windows-e2e --private --source=. --remote=origin --push
```

It is a five-file Node project with no dependencies: `src/slugify.js`, `test/slugify.test.js` (three cases, `node --test`), a `package.json`, a `ci.yml` that runs `npm test` on `ubuntu-latest`, and a `.gitattributes` carrying PR-1's rule for the same reason PR-1 exists.
Exactly one case fails at the seed commit (`'  Ahoy, Captain!  '` slugifies to `-ahoy-captain-`, not `ahoy-captain`), and CI is red on `main` at the seed (run `33264772591`, failure, 21 s) so the task is real on a Linux runner as well as here.

The detect-only bootstrap in the live home prints one line and exits 0:

```sh
FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh
#   NOTICE: auto-detected herdr runtime (HERDR_ENV=1) - spawning into the EXPERIMENTAL herdr backend.
```

Zero `MISSING`, zero `TANGLE`, zero `BACKEND_INVALID` - row 14 holding on the ported tree.

### C1. The primary comes up

```sh
herdr tab create --workspace w5 --cwd 'C:\Users\ebatt\firstmate' --label fm-primary --no-focus
#   tab w5:t5, root pane w5:p6, cwd C:\Users\ebatt\firstmate\
herdr pane run w5:p6 "claude --dangerously-skip-permissions"
```

Claude Code 2.1.251 starts in the pwsh pane and shows its folder-trust dialog, which needs one `down` and one `enter` through `pane send-keys`.
Then `Ahoy. Start the session.`, and the first mate runs `bin/fm-session-start.sh` itself: 32 s, 8 lines, lock acquired, network checks 12 s, `gh` authenticated, no queued notifications, no registry yet.

The session lock is the first place a Phase B slice shows up in production rather than in a test:

```sh
$ cat C:/Users/ebatt/firstmate/state/.lock
255612
$ pwsh -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process -Filter 'ProcessId=255612' | Select-Object ProcessId,ParentProcessId,Name"
#   255612  218832  claude.exe
$ kill -0 255612
#   bash: kill: (255612) - No such process
$ bash -c '. bin/fm-proc-lib.sh; fm_pid_alive 255612 && echo alive'
#   alive
```

The lock names the primary's Win32 pid, `kill -0` calls it dead, and `fm_pid_alive` calls it alive.
That is findings 2 and 3 held up against a real session: before slice 1 the lock could not be written at all here, and any liveness probe of it would have answered "dead".

### C2. One order, one crewmate, one PR

The captain's message registers the project and asks for the fix, explicitly delegated.
The first mate:

1. cloned into `projects/fm-windows-e2e` (its first attempt was refused by the cd guard for a top-level `cd`, which is the guard behaving, and it retried path-scoped),
2. wrote `data/projects.md`:
   `- fm-windows-e2e [direct-PR] - Sandbox Node project ... (added 2026-08-29)`,
3. filed a backlog item and a brief, and ran
   `bin/fm-spawn.sh slugify-trim-k1 projects/fm-windows-e2e --mode direct-PR --yolo off --effort low`.

The spawn produced a crewmate tab in its own workspace, and `state/slugify-trim-k1.meta` records the whole shape of it:

```
window=default:w7:p2       backend=herdr        herdr_workspace_id=w7
worktree=/c/Users/ebatt/.treehouse/fm-windows-e2e-e86758/1/fm-windows-e2e
project=/c/Users/ebatt/firstmate/projects/fm-windows-e2e
harness=claude  kind=ship  mode=direct-PR  yolo=off  effort=low
```

That is PR-3 and PR-4 doing their jobs together: the adapter accepted the drive-letter socket path (finding 5) instead of refusing the spawn, and the pane came up as a working shell in a treehouse worktree (findings 6 and 13).
The crewmate hit the same folder-trust dialog; the first mate answered it through the guarded sender.

Eleven minutes after the order:

```
state/slugify-trim-k1.status      done: PR https://github.com/EvanBatten/fm-windows-e2e/pull/1
state/slugify-trim-k1.busy-state  state=idle source=claude-hook event=stop
```

PR #1, `trim leading and trailing dashes from slugs`, one file, two lines:

```diff
-    .replace(/[^a-z0-9]+/g, '-');
+    .replace(/[^a-z0-9]+/g, '-')
+    .replace(/^-|-$/g, '');
```

Green on `ubuntu-latest` (run `33265421051`).

### C3. Merge and teardown

On the captain's `Merge it.`, the first mate ran the guarded merge script first, reported that it refused, and merged through the forge tool under the explicit instruction:

```
PR #1  MERGED 2026-08-29T17:36:47Z  merge commit 903a51c
main CI run 33266092171  success  15 s
```

`bin/fm-teardown.sh slugify-trim-k1` then stopped the worker, returned the treehouse worktree to the pool, closed the crewmate tab (`herdr tab list` drops `w7:t2`), and cleared every `state/slugify-trim-k1.*` file.
The backlog item is Done with its PR link.

The whole chain held: register, clone, brief, spawn on herdr, trust dialog, work, PR, CI, merge, cleanup - the first mate's own summary of it, and it matches what GitHub and `state/` say.

### C4. The Stop-hook wake: a measured blocker

This is the one leg that does not work, and it is worth the space because the cause is exact.

**The symptom.** At every turn end with work in flight, `bin/fm-turnend-guard.sh --claude` blocks the stop:

```
TURN WOULD END BLIND - SUPERVISION IS OFF
1 task(s) in flight, but no live watcher holds this home lock (last beat: never).
The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.
```

`state/.claude-autoarm-epoch` did not exist, so `bin/fm-claude-stop-autoarm.sh` had not claimed a generation on any firing.

**Not "the hook never runs".** That was the first mate's reading, and it is wrong.
A throwaway project with two Stop hooks - one plain, one `"asyncRewake": true` - run under `claude -p --dangerously-skip-permissions` writes both markers:

```sh
$ ls /tmp/fm-asynchook/*.marker
async.marker  sync.marker
```

Claude Code 2.1.251 fires `asyncRewake` Stop hooks on this Windows build.

**What actually happens.** Replacing those two hooks with a probe that walks its own ancestry:

```
label=sync  msyspid=48216  winpid=289396
--- Get-Process .Parent walk (what fm-proc-lib.sh uses) ---
289396  0  bash
--- Win32_Process ParentProcessId walk ---
289396  293396  bash.exe
293396  GONE
```

and the same for the async firing (`215548 -> 4808 -> GONE`).
A Claude Code hook on Windows is spawned through an intermediate process that has **already exited** by the time the hook body runs.
`Get-Process().Parent` returns null; `Win32_Process.ParentProcessId` returns the dead intermediate's pid and the walk ends there.
Both routes dead-end, so `fm_proc_chain "$$"` inside a hook returns exactly one row with ppid 0 - the hook's own bash and nothing above it.

`/proc/<pid>/ppid` is `1` inside the hook, which is the ordinary MSYS answer for "my parent is not an MSYS process", so the MSYS segment of the walk is one row too.
This is not a defect in slice 1's walk: the same chain from an ordinary Bash-tool shell in the same session resolves all seven hops to `herdr.exe`.
It is a property of how the harness starts a hook on Windows.

**Why that stops the arm.** `fm_harness_ancestry_pids` starts at `$$`, asks `fm_harness_process_matches` about `/usr/bin/bash` (no match), asks for the parent, gets nothing, and returns 1.
So `fm_session_lock_owned_by_self` is false, and the auto-arm takes its "not me" branch:

```sh
LOCK_PID=$(cat "$STATE/.lock")      # 255612, numeric - fine
fm_harness_pid_alive "$LOCK_PID" && exit 0
```

`fm_pid_alive 255612` is true (slice 1 made it true), so the hook reads a healthy lock held by somebody else and **exits 0 silently**, which is exactly the correct behavior for a competing session.
There is no bug in the gate. The input to the gate is unrecoverable.

**The A/B that settles it.** The same script run by the first mate from an ordinary Bash tool call, in the same home and the same minute, gets past the identity gate and does its whole job:

```
state/.claude-autoarm-epoch:
epoch=2 owner_pid=47483 outcome=rewake updated_at=1788024909
```

Same script, same state, same session - claims a generation from a Bash-tool shell, exits 0 silently from a hook.
The only difference between the two processes is whether their Win32 parent still exists.

**What it costs.** The watcher itself works: `state/.watch-deliveries.log` shows real deliveries,

```
44085  ...  signal: state/slugify-trim-k1.status state/slugify-trim-k1.turn-ended
47670  ...  stale: default:w7:p2
```

and `state/.watch-cycle-exits.log` shows both cycles closing with an actionable reason (`actionable-signal`, `actionable-stale`).
What is missing is the translation step: for a Claude primary, an actionable arm close is turned into a wake by the Stop hook exiting 2 with a banner on stderr, and by the same hook re-arming for the next cycle.
Without an identity, neither happens, so each cycle is the last one and the first mate must arm the watcher by hand at every turn end - which it did, twice, and the turn-end guard blocked it twice more when a cycle closed before the next arm.

**Verdict at the time of the run:** a documented blocker with evidence.
The fix had to give a hook an identity that does not depend on its parent still being alive - the Stop payload's own `session_id`, recorded beside the pid in the lock and compared by equality.
That is what slice 8 below implements, after finding out *why* the parent is gone.

### C4b. Root cause of the severed ancestry, and the fix (slice 8)

C4 above stops one question short: it proves the hook's Win32 parent is gone and infers that this is simply "how the harness starts a hook on Windows".
It is not.

**The generalization was too wide.** A throwaway project whose Stop and SessionStart hooks each run `probe.sh <label>` - no `exec` - resolves its whole ancestry from inside all three hooks, in the same shape Phase C used (a real interactive `claude --dangerously-skip-permissions` in a herdr pwsh pane, Claude Code 2.1.251):

```
1780    296896  /usr/bin/bash                        bash /tmp/fm-hookprobe/probe.sh sessionstart
296896  296956  C:/Program Files/Git/bin/../usr/bin/bash
296956  294192  C:/Program Files/Git/bin/bash
294192  264860  C:/Users/ebatt/.local/bin/claude
264860  215332  .../PowerShell_7.6.5.0/pwsh
215332  0       C:/Users/ebatt/AppData/Local/Programs/herdr/herdr
```

`fm_harness_ancestry_pids` prints `294192` there - the identity gate would have passed.
The same probe fires for the synchronous Stop hook, for the `asyncRewake` Stop hook, and for the `asyncRewake` hook even when the *synchronous* Stop hook exits 2 first (both markers are written 9 ms apart), so none of "async hooks do not run", "a blocking guard suppresses them", or "hook ancestry is always severed" is the explanation.

**What is.** `bash -x` around the real hook, driven by the credentialed live E2E below, shows the walk dying at the boundary:

```
+++ pwsh -NoProfile -NonInteractive -Command '... Get-Process -Id 296196 ... $p.Parent ...'
++++ out='296196   0   C:\Program Files\Git\usr\bin\bash.exe'
```

The hook's own bash has no Win32 parent. It is reached through the tracked registration's `exec`:

```json
"command": "[ -z \"${GROK_AGENT:-}${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh"
```

MSYS cannot implement POSIX `exec` on Windows: it starts a NEW Win32 process, hands it the same Cygwin pid, and exits the old one.
The replacement therefore has a Win32 parent that is already dead and an MSYS ppid of `1`.
Isolated with a native launcher so no MSYS parent can mask it (`pwsh -c "& 'C:\Program Files\Git\usr\bin\bash.exe' -c '<form>'"`):

```
exec /tmp/execprobe.sh EXEC      msyspid=12251 winpid=265292  parent=NULL  msys-ppid=1
/tmp/execprobe.sh NOEXEC         msyspid=12257 winpid=291968  parent=NULL  msys-ppid=1
/tmp/execprobe.sh NOEXEC2; :     msyspid=12264 winpid=292176  parent=NULL  msys-ppid=12263
```

The middle row is the important one: dropping the word `exec` changes nothing, because bash exec-optimizes the FINAL command of a `-c` script anyway.
Only a command that is not last (`cmd; :`) keeps a live parent.
So the severing is not a harness behavior at all - it is `exec` meeting MSYS, and every tracked hook entry in `.claude/settings.json`, `.codex/hooks.json` and the Cursor registration is written in exactly the form that triggers it.
Editing the registrations out of it would be a fix that depends on an optimizer's discretion; the identity has to stop depending on the parent instead.

**A local reproduction, in three minutes.** `tests/fm-claude-stop-autoarm-live-e2e.test.sh` is the opt-in credentialed regression for precisely this mechanism - real Claude Code, the real tracked hook registration, an isolated home and project - and it reproduces the Phase C blocker exactly:

```sh
FM_CLAUDE_LIVE_E2E=1 bash tests/fm-claude-stop-autoarm-live-e2e.test.sh
#   not ok - expected exactly 2 hook-owned arm cycles, got :
```

with the same fingerprint the live run had: no `state/arm-ran`, no `state/.claude-autoarm-epoch`, the model woken only by the synchronous guard's `TURN WOULD END BLIND`, and two model-issued drains.
Phase C did not need a captain, a crewmate or a sandbox repo to be reproduced - it needed one command.

**The fix.** `state/.lock` keeps its one-bare-pid format, which fourteen readers in `bin/` and every fixture in `tests/` depend on (`fm_session_lock_owned_by_self` itself rejects a lock that is not purely numeric, so a second line there would make every session on every platform lock-less).
The identity goes in a sidecar `state/.lock.session` holding `<pid> <session-id>`, written by `bin/fm-lock.sh` - the single acquisition owner - inside the same claim hold that publishes the lock, and REMOVED rather than left stale when the acquiring harness has no session identity.
`bin/fm-claude-stop-autoarm.sh` lifts `.session_id` out of the Stop payload it already reads and offers it as a second proof at the identity gate only; everything downstream is untouched.
`fm_session_lock_owned_by_session` accepts only when every one of these holds:

| Clause | Why it is there |
| --- | --- |
| the id is 8-128 chars of `[A-Za-z0-9._-]` | it is written to a state file and compared by equality |
| the sidecar is a regular non-symlink file with a `<pid> <id>` line | same shape check `fm-lock.sh` applies to the lock |
| its pid equals the current lock pid | a pair left by an earlier session can never speak for this one |
| its id equals the id in the payload | read from the PAYLOAD, never the environment: a watcher or background job inherits the owner's `CLAUDE_CODE_SESSION_ID`, and only the harness can deliver a Stop payload |
| `fm_harness_ancestry_pids` found NO harness at all | when the walk can name one, that answer decides - which is what leaves macOS and Linux byte-identical |
| the lock pid is still a live harness | otherwise the fallback would prove only that a session with this id *once* wrote the lock, and a resumed session would adopt a home nobody holds instead of going through `fm-lock.sh`'s guarded recovery |

The write side reads `FM_HARNESS_SESSION_ID` if set, else `CLAUDE_CODE_SESSION_ID`.
Measured on this machine, Claude Code 2.1.251: that variable is present in every hook process AND every Bash-tool shell, equals the payload's `session_id` for SessionStart and Stop alike, and a NESTED `claude -p` started from inside another session OVERRIDES it with its own id (outer `fddf2b81-...`, nested probe `cf40bab8-...`) rather than inheriting it.
The override is load-bearing and is written into the code comment so a harness upgrade re-verifies it.
The environment is the only source that covers how the lock is really acquired: in Phase C the lock was written by `bin/fm-session-start.sh` run as a Bash tool call, not by the SessionStart hook, so a payload-only write side would have recorded nothing.
It is not a documented interface; when it disappears no pair is recorded, the fallback never fires, and every platform degrades to exactly today's ancestry-only behavior.

**The proof, same command as the reproduction:**

```
state/arm-ran               arm-run=1 pid=2528
                            arm-run=2 pid=2814
state/.claude-autoarm-epoch epoch=2 owner_pid=2620 outcome=rewake updated_at=1788059041
state/.lock                 290904
state/.lock.session         290904 72f4bae3-c833-4a72-9dd1-6eace83be8ea
```

and in the transcript, two rewake deliveries that came from the hook rather than the guard:

```
Stop hook feedback: [... exec "$CLAUDE_PROJECT_DIR"/bin/fm-claude-stop-autoarm.sh]:
  firstmate watcher wake - one supervision event needs a handling turn now.
  stale: fixture-rapid-1
...
  stale: fixture-rapid-2
```

Two tokenless Stop-owned arm cycles, two hook-owned rewakes, three drains, zero model-issued arm commands, the stale dead-owner lock reclaimed through session start - nine of the regression's ten assertions, from zero before the fix.

**The tenth assertion, and what it measures.** `! grep -q 'TURN WOULD END BLIND'` still fails: at the FIRST Stop of a session the synchronous guard blocks once before the auto-arm has claimed.
It is a latency finding, not an identity one, and it is worth exact numbers (finding 27):

```
1788053788659 START guard      1788053788673 START autoarm     (14 ms apart)
1788053798790 END   guard rc=2 1788053803837 END   autoarm rc=2 (guard gave up at 10.1 s)
1788053811423 START guard      1788053811519 START autoarm
1788053813903 END   guard rc=0 1788053825764 END   autoarm rc=2 (later Stops allow in 2.4 s)
```

The auto-arm's identity proof alone costs `2130 ms` (`fm_session_lock_owned_by_self`) plus `3009 ms` (the fallback) in the severed-hook shape, because each ancestry walk spawns a PowerShell, and `fm_pid_alive` on a NATIVE pid costs `1.2 s` because `kill -0` fails and `ps -W` scans the whole Win32 process table.
The guard's cooperation window is expressed as `SYNC_WAIT_MS / 100` iterations of a `sleep 0.1` plus one poll, which assumes a free poll; measured here that loop actually spends 5.5 s for its nominal 800 ms (`wait=0` 3394 ms, `wait=800` 8896 ms, `wait=8000` 52845 ms - about 620 ms per iteration).
Raising the budget alone would make the guard hold the turn for the better part of a minute, so the honest fix is a deadline rather than an iteration count, sized from a measured time-to-claim.
That is left for a follow-up slice with its own measurement; the cost today is one forced continuation at the first Stop of a session, and every later Stop is clean.

**Not fixed here, and newly visible.** `tests/fm-claude-stop-autoarm.test.sh` could not run at all on any platform: `install_autoarm_scripts` copies `fm-wake-lib.sh` but not `bin/fm-proc-lib.sh`, which slice 1 made it source, so the hook died on `FM_PROC_UNAME: unbound variable` at the first case.
That is the sixth site of the same omission slice 6 fixed in five files.
With it copied, and with two `[ "$i" -lt 50 ]` fixture waits raised to 400 (a 2.5 s bound on a platform where the hook needs 5 s to reach its arm - the same timing-assumption class slice 6 removed from `fm-herdr-lab`), the suite goes from 0 to 36 green here and stops at one deterministic red:

```
not ok - the superseded owner must exit 0 instead of double-translating: expected exit 0, got 2
```

Reproduced with the product code stashed, so it is not this slice's doing (finding 28), and it belongs to the portable-serial lane's triage where every red gets a class.

`tests/fm-turnend-guard.test.sh` had the same omission at two more sites, plus two of the open-coded fakebin symlink loops slice 4 named (a symlinked MSYS binary in a curated PATH cannot load `msys-2.0.dll`, so the guard exited 127 instead of failing open).
With those four fixed it runs 7 -> 43 green here and stops in the OpenCode plugin's node harness, which is slice 6's `spawn()`-cannot-execute-a-shebang finding rather than anything about the guard.
One case in between, `test_hook_runs_fast`, sits exactly on its own 3 s bound because of finding 27 and flips either way on a loaded box - a timing assumption that a deadline-based cooperation window would also settle.

### C5. Findings this run added to the ledger

| # | Subsystem | Result | Measured detail | Fix owner |
| --- | --- | --- | --- | --- |
| 22 | Hook process ancestry | **FIXED** | MSYS cannot implement POSIX `exec` on Windows: it starts a new Win32 process, gives it the old Cygwin pid, and exits the original, so anything reached through `exec` - which is how every tracked hook entry is written, and what bash does anyway to a `-c` script's final command - has a dead Win32 parent and MSYS ppid 1. Both halves of the walk dead-end, `fm_session_lock_owned_by_self` can never be true in a hook, and `bin/fm-claude-stop-autoarm.sh` exited 0 at its identity gate on every firing. Not a harness behavior: a hook command that is NOT the shell's final command keeps its parent, and the same probe resolves seven hops to `herdr.exe` from a Bash-tool shell. Fixed by recording the harness session id beside the pid (`state/.lock.session`) and accepting the Stop payload's `session_id` when, and only when, the walk finds no harness at all (C4b). | slice 8; proven by `tests/fm-claude-stop-autoarm-live-e2e.test.sh` |
| 23 | git path form vs shell path form | **FAIL** | `git rev-parse --show-toplevel` answers `C:/Users/ebatt/firstmate/projects/fm-windows-e2e` while `pwd -P` answers `/c/Users/ebatt/firstmate/projects/fm-windows-e2e`. Six sites compare the two forms directly (`bin/fm-fleet-sync.sh:315`, `bin/fm-spawn.sh:1744`, `bin/fm-teardown.sh:1207`, `bin/fm-control.sh:693`, `bin/fm-config-inherit-lib.sh:163`, and the isolation instruction `bin/fm-brief.sh` gives every crewmate). Measured effect: `bin/fm-fleet-sync.sh` skips every project clone, so a merged PR never reaches the local clone. | a Phase B follow-up slice; one comparison helper, not six branches |
| 24 | Guarded PR merge | **FAIL** | `bin/fm-pr-merge.sh` refuses because it insists on the PR-poll registration that `fm_pr_poll_prepare` cannot do here (`error: could not prepare PR poll`, row 21 / D6). The captain's merge had to go through the forge tool directly. | row 21 / decision D6 |
| 25 | Watcher identity across a clock step | **FAIL, provisional** | `fm_wake_identity`'s `proc-starttime` is `/proc/<pid>/stat` field 22, and its comment says that field is "immune to the wall-clock steps". That is true on Linux and false on Cygwin, which derives it from `btime` (`now - uptime`), so a wall-clock step shifts it for every pid at once. Observed once here: the recorded watcher identity `936149599` against a live `936148558`, a 1041-tick drift, after the machine slept and resumed mid-run - which made `fm_watcher_healthy` report a live, lock-holding watcher as dead. Field 22 and `/proc/stat`'s `btime` were both stable over 75 s with no step, so a step is what it takes. | a Phase B follow-up; the identity needs a step-immune component on MSYS |
| 26 | Tracked symlink at checkout | **FAIL** | Git for Windows ships `core.symlinks=false` in its SYSTEM config, so a plain clone materializes a tracked symlink as a regular text file holding its target path. This repository has exactly one tracked symlink and it is `.claude/skills -> ../.agents/skills`, which is how Claude Code is shown firstmate's twenty skills. In the live home it was a 17-byte file, so `/bearings` answered `Unknown command: /bearings` and the first mate had run this entire session with zero skills loaded. `git config core.symlinks true` plus `git checkout -- .claude/skills` restored the link (Developer Mode is on, so no admin step), and Claude Code picked the skills up live in the already-running session: `20 skills available`. | PR-1's territory: a setup step, not a repo file - `.gitattributes` cannot express it |
| 27 | Stop-hook cooperation window | **FAIL** | The synchronous guard waits `SYNC_WAIT_MS / 100` iterations of `sleep 0.1` plus one poll for the auto-arm to claim, which assumes a free poll. Measured here: `wait=0` 3394 ms, `wait=800` 8896 ms, `wait=8000` 52845 ms - about 620 ms per iteration, because `fm_pid_alive` on a native pid falls back to a whole-table `ps -W` (1.2 s). Meanwhile the auto-arm's identity proof alone is 2130 ms + 3009 ms in the severed-hook shape, so the first Stop of a session costs one forced continuation (`TURN WOULD END BLIND`) before the hook can claim. Every later Stop allows in 2.4 s. | a follow-up slice: a deadline instead of an iteration count, sized from a measured time-to-claim (C4b) |
| 28 | `fm-claude-stop-autoarm` suite | **FAIL, 1 of 37** | `install_autoarm_scripts` never copied `bin/fm-proc-lib.sh`, which slice 1 made `fm-wake-lib.sh` source, so the whole suite died on `FM_PROC_UNAME: unbound variable` at case 1 on every platform - the sixth site of slice 6's omission. `tests/fm-turnend-guard.test.sh` had two more, plus two open-coded fakebin symlink loops. With those fixed and two 2.5 s fixture waits raised, the suite runs 36 green and stops at `the superseded owner must exit 0 instead of double-translating: expected exit 0, got 2`, reproduced with the product code stashed. | the portable-serial lane's triage |

Row 24 is the D6 trigger the plan predicted in slice 6, arriving exactly where slice 6 said it would.

Row 25 is labelled provisional on purpose.
Its trigger was a suspend/resume of the machine partway through this run - which is also why the first mate's own elapsed-time readings in the transcript read as five and a half hours - and a deliberate re-measurement (sleep the machine, re-read one long-lived pid's field 22) was not done.
The mechanism is not in doubt and the trigger is routine rather than exotic: any laptop that closes its lid moves Cygwin's `btime`.
The size and the frequency are what is unmeasured.

### C6. The second task, and what is left

A second order (`slugify-empty-k2`: assert that a punctuation-only title slugifies to the empty string) was given specifically to set the wake proof up: spawn, then leave the primary idle and see whether the crewmate's finish reaches it.
The crewmate delivered [PR #2](https://github.com/EvanBatten/fm-windows-e2e/pull/2) into the same sandbox from a fresh pool slot, so the spawn path is reproducible rather than a one-off.
The wake did not arrive by the Stop-hook route, for the reason in C4; what did reach the primary unprompted was the completion notification of the arm job it had launched as a tracked background shell, which is the same mechanism `bin/fm-watch.sh`'s header names ("what wakes the LLM through the background-task completion") but only while the primary itself keeps launching that job.

`/bearings` was the last step, and it is what turned up row 26.
Typed into the pane it answered `Unknown command: /bearings`, because `.claude/skills` was a 17-byte regular file rather than the symlink git has tracked all along; with the symlink restored, the running session picked the skills up without a restart (`20 skills available`) and the digest came back clean:

```
Captain's Call     Nothing needs your action right now, captain.
Recently Landed    PR #1 - slugify no longer leaves a leading or trailing dash; merged and cleaned up.
                   PR #2 - test that a punctuation-only title slugifies to the empty string; merged and cleaned up.
Underway           Nothing is underway.
Charted Next       Nothing is queued.
```

The live home is left checked out on `windows`, only the `fm-primary` tab created here is left open, and no tab created by anyone else was touched.

## What the spike did not know

- The upstream spike sources `bin/fm-backend.sh` on `windows-latest`; `actions/checkout` there uses Git for Windows defaults, so row 1 applies to CI too until `.gitattributes` lands.
- Row 13's `ESC]9;9;` hook is the whole reason `cwd` works for pwsh on Windows; any shell firstmate launches in a pane must emit it.
- Row 12's conversion also affects `--cwd` in the wanted direction, so a blanket `MSYS_NO_PATHCONV=1` on every herdr call would break pane launch cwds; the fix must be per-argument.

## Repro commands

```sh
# row 1
file bin/*.sh | grep -c CRLF
# rows 2 and 3 (the shipped walk; prints the whole chain to herdr.exe)
bash -c '. bin/fm-proc-lib.sh; fm_proc_chain_prime "$$"; printf "%s\n" "$FM_PROC_CHAIN_MEMO"'
bash -c '. bin/fm-proc-lib.sh; fm_pid_alive <win32 pid>; echo $?'
env -u CLAUDECODE -u CURSOR_AGENT -u PI_CODING_AGENT -u GROK_AGENT bin/fm-harness.sh
# row 4
ln -s target link && readlink link
# rows 5 and 9 (the shipped adapter; both printed a refusal before PR-3)
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_presentation_session_socket_path default'
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_presentation_lock_namespace_valid /tmp/firstmate-herdr-presentation; echo $?'
mount; mkdir -m 700 /tmp/probe; stat -c %a /tmp/probe
# row 12 (the conversion, then the shipped adapter's answer to it)
herdr tab list --workspace /clear --session default
MSYS2_ARG_CONV_EXCL='*' herdr tab list --workspace /clear --session default
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_win32_cli; echo $?'
# rows 6 and 13 (the shipped adapter; needs a lab session, see bin/fm-herdr-lab.sh)
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_win32_pane_bash; echo'
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_task_tab_create <lab> w1 "$PWD" fm-probe'
bash -c '. bin/backends/herdr.sh; fm_backend_herdr_current_path <lab>:<pane>'
herdr pane get <pane> --session <lab> | jq -c '.result.pane | {cwd, foreground_cwd}'
# the CRLF finding
printf '{"a":["x","y"]}' | jq -r '.a[]' | od -c
# slice 4 (each of these printed the wrong answer before the fix)
node bin/fm-arm-command-policy.mjs --command 'bin/fm-watch-arm.sh &' --root "$PWD" --home "$PWD"
node bin/fm-arm-command-policy.mjs --command "source '$PWD/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180" --root "$PWD" --home "$PWD"
node -e 'console.log(JSON.stringify(process.argv.slice(2)))' --root /c/fm --home /c/fm
printf '%s' '{"tool_input":{"command":"bin/fm-watch-arm.sh &"}}' | bin/fm-arm-pretool-check.sh; echo $?
# slice 5 (row 19, and the checksum defect; both installs failed before the fix)
export RUNNER_TEMP='C:\Users\ebatt\AppData\Local\Temp\fm-probe'; mkdir -p "$RUNNER_TEMP"
bin/fm-install-shellcheck.sh "$RUNNER_TEMP/bin"
bin/fm-install-actionlint.sh "$RUNNER_TEMP/bin"
echo hi > "$RUNNER_TEMP/f"
sha256sum "$RUNNER_TEMP/f"    # leading backslash, and every field shifted
sha256sum <"$RUNNER_TEMP/f"   # clean
bin/fm-lint-workflows.sh
# slice 6 (each of these printed the wrong answer before the fix)
printf 'a\r\nb\r\n' > /tmp/t.txt
LC_ALL=C grep -q $'\r$' /tmp/t.txt; echo $?     # 1 - GfW grep strips the CR
LC_ALL=C awk '/\r$/{f=1} END{exit !f}' /tmp/t.txt; echo $?   # 1 - so do awk and sed
bash -c '. bin/fm-proc-lib.sh; fm_proc_pgid $$; echo rc=$?'
ps -o pgid= -p $$ ; cat /proc/$$/pgid
x=$'\u2580'; printf '%s' "$x" | od -c | head -1   # literal escape text, no LANG
LANG=C.UTF-8 LC_ALL=C.UTF-8 bash -c 'printf "%s" $'"'"'\u2580'"'"'' | od -c | head -1
f() { local n=$1; shift; HERDR_SESSION="$n" /usr/bin/sleep 30 "$@"; }
f x >/dev/null 2>&1 & p=$!; ps -f | awk -v p="$p" '$3==p {print "CHILD:", $2, $NF}'
kill -TERM "$p"; ps -f | awk '{print $2, $3, $NF}' | grep sleep   # orphaned, still alive
: > /tmp/probe600 && chmod 0600 /tmp/probe600 && stat -c '%a' /tmp/probe600   # 644
# Phase C row 22 (hook ancestry; both walks dead-end from inside a hook)
#   put this in a throwaway project's .claude/settings.json as a Stop hook and run `claude -p`
pwsh -NoProfile -NonInteractive -Command '$id=[int]$env:FM_Q; for ($i=0; $i -lt 16 -and $id -gt 0; $i++) { $w=Get-CimInstance Win32_Process -Filter "ProcessId=$id"; if (-not $w) { "{0}`tGONE" -f $id; break }; "{0}`t{1}`t{2}" -f $w.ProcessId,$w.ParentProcessId,$w.Name; $id=[int]$w.ParentProcessId }'
# Phase C row 23 (the two path forms that are compared to each other)
cd <any clone>; git rev-parse --show-toplevel; pwd -P
# Phase C row 24 (the guarded merge's refusal)
bin/fm-pr-check.sh <task>   # error: could not prepare PR poll
# Phase C row 25 (stable without a clock step; a step is what moves it)
bash -c 'tail -f /dev/null & p=$!; s=$(cut -d")" -f2 /proc/$p/stat | cut -d" " -f21); timeout 75 tail -f /dev/null; cut -d")" -f2 /proc/$p/stat | cut -d" " -f21; echo "$s"; kill $p'

# slice 7 (the split, and the two checks that make it exact)
git log --oneline upstream/main..0865847 -- bin/fm-proc-lib.sh     # 0865847 and 9286fe7, nothing else
git diff pr-2-proc-lib:bin/fm-proc-lib.sh 0865847:bin/fm-proc-lib.sh   # empty
git diff --name-only upstream/main 0865847  # every path must land in a pr-* branch or be integration-only
git log --oneline upstream/main..pr-4-herdr-windows-pane
```
