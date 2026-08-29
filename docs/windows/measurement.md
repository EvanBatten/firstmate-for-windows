# Windows measurement

Phase A's findings ledger is the table below; each Phase B slice appends its own section as it lands.

## Phase A findings ledger

Measured 2026-08-29 on Windows 11 26200 against upstream `f66be0f` (2026-08-28).
Toolchain: Git Bash 5.2.37 (MINGW64), herdr 0.8.2 stable (protocol 20), treehouse 2.3.0, no-mistakes 1.57.0, Claude Code 2.1.251 (native `claude.exe`), gh 2.89, jq 1.6, node 24, tasks-axi 0.2.5, quota-axi 0.1.33, shellcheck 0.11, actionlint 1.7.12.
Developer Mode ON; user env `MSYS=winsymlinks:nativestrict`.
Same shape as the upstream `windows-herdr-spike.yml` table so the two can be read side by side.
The plan that owns the fix list is [plan.html](plan.html) (findings ledger numbers below match it).

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
| fm-backend-herdr | FAIL | "the ambiguity refusal did not name the candidate workspaces (missing: 'w1 w7')", yet the captured stderr names `(w1 w7)` | **product** - resolved in slice 3: Windows `jq` writes CRLF, so a multi-line read carries `w1\r` (see "New finding" below) |
| fm-arm-pretool-check | FAIL | "D01 via codex must deny, got exit 0" for `bin/fm-watch-arm.sh &` | **product** - resolved in slice 4: the watcher seatbelt was inert on Windows for three separate reasons (`node:path`, MSYS argument conversion, `jq` CRLF); now 145/145 |
| fm-crew-state | FAIL | "timed-out no-mistakes falls back to pane (missing: 'state: working')" | unknown; timing or `ps`-based liveness (row 2) |
| fm-herdr-lab | FAIL | "timed-out provision must fail: expected exit 1, got 0" | test/timing under slow spawn |
| fm-pr-merge | FAIL | "github-zero-exit-queue-required: refusal did not name the concrete observed state" | unknown (fake `gh` fixture) |
| fm-ensure-agents-md | FAIL | "CRLF AGENTS.md injection did not preserve CRLF line endings" | unknown; the one test that wants CRLF kept, worth a look next to row 1 |
| fm-composer-lib | FAIL | "a half-block rule row must count as a structural edge" | unknown; text-width or locale handling of block glyphs |

### portable-parallel-1: 5 green / 5 red / 1 gate-skip of 11 (903 s)

| Script | Result | First failing assertion | Class (provisional) |
| --- | --- | --- | --- |
| fm-composer-ghost, fm-grok-harness, fm-review-diff, fm-brief, fm-transition-lib | **PASS** | (fm-grok-harness passes only with `MSYS=winsymlinks:nativestrict`) | |
| fm-pi-primary-types | gate-skip | pi not installed | |
| fm-x-mode | FAIL | "poll auth error must write a dedupe marker" (next assertion wants `state/` at mode 700) | platform: row 21 |
| fm-cd-pretool-check | FAIL | "transport must fail open when node is unavailable: expected exit 0, got 127" | **test** - resolved in slice 4: a curated `PATH` of symlinked MSYS binaries cannot load `msys-2.0.dll`, so the child dies before the guard runs; the guard itself fails open correctly |
| fm-captain-hold-lifecycle | TIMEOUT | exceeded the 300 s per-script bound (failed in 11 s without the env var) | unknown; hang once symlinks are real, investigate with `bash -x` |
| fm-test-run | FAIL | "isolation failure: worker root mode is 755, expected 0700" | platform: row 21 (the runner's own `--jobs` isolation check) |
| fm-lint | FAIL | "installer did not fall back to shasum -a 256" | test: exercises `fm-install-shellcheck.sh`, which dies on `uname` (row 19) before the fallback |

### Count to beat

11 green, 12 red, 1 gate-skip across the 24 portable-parallel scripts, plus 14 of 15 in the real-herdr smoke test.
Of the 12 red, 3 are row 21 (POSIX modes), 1 is row 19, 2 were the guard fail-open suspects (`fm-arm-pretool-check`, `fm-cd-pretool-check`, both green after slice 4), 1 is `fm-backend-herdr` (green after slice 3), 1 is a timeout, and 4 need a first look.
The 131-script portable-serial lane was not run in Phase A (roughly 3 hours at this box's spawn rate); Phase B runs it once the row 21 decision is applied.

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
```
