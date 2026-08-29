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
| fm-backend-herdr | FAIL | "the ambiguity refusal did not name the candidate workspaces (missing: 'w1 w7')", yet the captured stderr names `(w1 w7)` | test (assertion text match; check for `\r` or quoting in the capture) |
| fm-arm-pretool-check | FAIL | "D01 via codex must deny, got exit 0" for `bin/fm-watch-arm.sh &` | product-suspect: the watcher-protection guard fails OPEN on the codex path; top of the Phase B list |
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
| fm-cd-pretool-check | FAIL | "transport must fail open when node is unavailable: expected exit 0, got 127" | product-suspect: the cd guard's no-node fallback exits 127 instead of failing open; sibling of the arm-pretool finding |
| fm-captain-hold-lifecycle | TIMEOUT | exceeded the 300 s per-script bound (failed in 11 s without the env var) | unknown; hang once symlinks are real, investigate with `bash -x` |
| fm-test-run | FAIL | "isolation failure: worker root mode is 755, expected 0700" | platform: row 21 (the runner's own `--jobs` isolation check) |
| fm-lint | FAIL | "installer did not fall back to shasum -a 256" | test: exercises `fm-install-shellcheck.sh`, which dies on `uname` (row 19) before the fallback |

### Count to beat

11 green, 12 red, 1 gate-skip across the 24 portable-parallel scripts, plus 14 of 15 in the real-herdr smoke test.
Of the 12 red, 3 are row 21 (POSIX modes), 1 is row 19, 2 are guard fail-open suspects (`fm-arm-pretool-check`, `fm-cd-pretool-check`), 1 is a timeout, and 5 need a first look.
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
# row 13 (needs a lab session; see bin/fm-herdr-lab.sh)
herdr tab create --workspace w1 --cwd C:\path --env 'PROMPT_COMMAND=printf "\033]9;9;%s\033\\" "$(cygpath -w "$PWD")"' --no-focus --session <lab>
herdr pane run <pane> "& 'C:\Program Files\Git\usr\bin\bash.exe' --login" --session <lab>
herdr pane get <pane> --session <lab> | jq .result.pane.cwd
```
