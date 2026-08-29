# PR-2: put process identity and liveness behind one library

Branch: `EvanBatten:pr-2-proc-lib` -> `kunchenguid/firstmate:main`.
Two commits, 14 files, +991 -28, of which +924 is the new library and its test.
Depends on nothing; PR-1 makes it *runnable* on Windows but this branch is correct without it.

## What is wrong today

firstmate asks two questions about processes in several places: "what process is this?" and "is it still alive?".
Both are asked with commands that do not exist in the form used on a Windows userland.

`ps -o comm= -p <pid>` is the identity call, and MSYS `ps` has no `-o` at all:

```console
$ ps -o comm= -p $$
ps: unknown option -- o
```

`kill -0 <pid>` is the liveness call, and it answers "gone" for a live process whenever that pid is a Win32 pid rather than an MSYS one - which is every process firstmate actually cares about, because `claude.exe`, `herdr.exe` and `node.exe` are native binaries with no MSYS pid:

```console
$ ps -W | grep -c 283196     # claude.exe, alive
1
$ kill -0 283196; echo $?
1
```

The consequences are not cosmetic:

- `bin/fm-harness.sh` `detect_own` cannot resolve the harness by ancestry, so it reports `unknown` and every downstream decision keyed on the harness type is wrong.
- `bin/fm-session-lock-lib.sh` cannot compute the ancestry it locks against, and its `fm_harness_pid_alive` reads a live holder as dead.
- `bin/fm-wake-lib.sh`'s `fm_pid_alive` has the same false negative.
- `bin/fm-procevent.sh` cannot read a runner's process group (`ps -o pgid=`), so `fm-procevent.sh start` aborts on **every** source with `cannot inspect runner process group`, and every captured-result channel is dead.
- `bin/fm-watch.sh` silently skips the proof that its check subshell leads its own group.
- `bin/fm-sessionstart-nudge.sh` decides no lock holder is in its ancestry, so the SessionStart nudge fires at a primary that has already run `fm-session-start.sh`, every session.

## The fix

A new leaf library, `bin/fm-proc-lib.sh`, owns the two questions and nothing else:
`fm_proc_comm`, `fm_proc_args`, `fm_proc_ppid`, `fm_proc_pgid`, `fm_proc_chain`, `fm_proc_chain_prime`, `fm_pid_alive`.

**The POSIX branch runs literally the commands its callers ran before.**
That is the design constraint, not an aspiration: each function's POSIX arm is the same `ps -o ... -p "$pid"` pipeline or the same `kill -0`, moved rather than rewritten, so macOS and Linux behavior is byte-identical by construction.
The one measurable cost on those platforms is a single `uname -s` fork per script that sources the library.

The MSYS branch is a hybrid walk, because neither half works alone:

- MSYS publishes process facts as files under `/proc/<pid>/` - `exename` (exactly what `ps -o comm=` prints), `ppid`, `pgid`, `winpid`, and a real NUL-separated `cmdline`. Reading those spawns no process at all, and the PPIDs are correct *between MSYS processes*.
- The trail stops at the MSYS/Win32 boundary, where a bash spawned by a native process reports PPID 1. From `/proc/<pid>/winpid` the walk hands off to one `pwsh -NoProfile -NonInteractive` `Get-Process` + `.Parent` traversal for the whole Win32 segment.
- Liveness falls back to the `WINPID` column of `ps -W`, which sees native processes that `kill -0` cannot.

### The route was chosen by measurement, not by shape

The obvious implementation - one `Get-CimInstance Win32_Process -Filter "ProcessId=N"` per hop - is 25x too slow. Timed against the real six-hop chain on this machine (`bash` -> `bash` -> `claude.exe` -> `node.exe` -> `pwsh.exe` -> `herdr.exe`):

| Approach | Wall time |
| --- | --- |
| one filtered `Get-CimInstance` per hop | 22.0 / 23.2 / 24.1 s |
| one bulk `Get-CimInstance Win32_Process` | 4.7 / 5.1 s |
| `Get-Process -Id` plus repeated `.Parent` | 0.96 s |
| bare `pwsh -NoProfile -NonInteractive -Command 1` (the floor) | 0.75 / 0.79 s |
| reading `.CommandLine` off each PS7 `Process` | 38.3 s |
| `ps -W` | 0.91 s |

`.CommandLine` on a PowerShell 7 `Process` object is a hidden per-process CIM query, which is where the 38 s goes, so the library never reads it.
The shipped walk costs 64 ms for the `/proc` segment plus 828 ms for one pwsh start.

### Why callers gained one line

Every caller reads process fields inside `$(...)`, and a subshell cannot write back to its parent, so a memo that filled itself lazily would be discarded on every hop and the walk would cost one pwsh process per field.
Each caller therefore calls `fm_proc_chain_prime "$pid"` once before its loop.
On macOS and Linux that call returns 0 without forking.
`tests/fm-proc-lib.test.sh` asserts this cost contract directly, by counting invocations of a fake `pwsh`.

### The branch is chosen by capability, not by platform

An earlier version keyed only on `uname -s`, and that silently broke every test in `tests/` that shims a `ps` to model a process table: on Windows the library ignored the fixture and walked the real process tree.
The shipped version asks `uname` first and then, only if that says Windows, probes `LC_ALL=C ps -o comm= -p $$`.
A `ps` that accepts `-o` wins.
macOS and Linux never run the probe.

The `LC_ALL=C` pin is load-bearing rather than cosmetic: `tests/fm-watcher-lock.test.sh` records the locale its stub `ps` was called under and fails if any call arrives without it.

## What did not change

`bin/fm-backend.sh` is untouched.
Its only `ps` use is inside `fm_backend_detect_cmux_app_is_ancestor`, reachable solely from `fm_backend_detect_cmux_fallback`, whose first line is `[ "$(uname 2>/dev/null)" = Darwin ] || return 1` (bin/fm-backend.sh:174), so it has no non-Darwin path.

## Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on every touched file | clean, ShellCheck 0.11.0, full extended analysis |
| `tests/fm-proc-lib.test.sh` (new, 15 cases) | 15 / 15, both branches, on Windows and on a POSIX host |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `bin/fm-harness.sh` with every marker unset, on Windows | `claude` in 2.4 s (was `unknown`) |
| `fm_harness_ancestry_pid` on Windows | `283196`, `claude.exe`'s Win32 pid (was: could not resolve) |
| six named suites, before and after, in a worktree at `HEAD` | fail at the identical assertion, so no regression |
| `tests/fm-watcher-lock.test.sh` | one real regression found and fixed during review (the locale pin) |

`tests/fm-proc-lib.test.sh` fakes `uname`, `ps` and `pwsh`, mirroring how `tests/fm-backend-herdr.test.sh` fakes `herdr`, so **the MSYS branch is covered on Linux and macOS CI too**.
That is what keeps this patch from being code no CI ever executes.

## Notes for the reviewer

Two things worth your attention:

**Exit statuses at the four `pgid` sites are newly meaningful.**
The old `ps -o pgid= -p "$pid" | tr -d '[:space:]'` pipeline always exited 0 - that is `tr`'s status - so the `|| die` and `|| return 2` arms written beside it were dead code on every platform.
They stay dead on POSIX, because the library's numeric guard is unreachable there.
On MSYS they newly fire, always in the refusing direction: the digits-only guard rejects a CR, whitespace, multiple fields and garbage, so `stop_runner_pid` can never be handed a group it did not validate.

**One consequence is recorded, not fixed here.**
On MSYS the session lock necessarily records the harness's **Win32** pid, because a native `claude.exe` has no MSYS pid at all.
`fm_harness_pid_alive` and `fm_pid_alive` handle that, but `bin/fm-lease-lib.sh:147` still probes the same pid with a bare `kill -0` inside `fm_lease_live`, so on Windows a live Pi lease reads as stale.
That fails closed and is gated on `PI_CODING_AGENT`/`FM_SUPERVISION_ACTOR`, so it is called out here rather than folded into a patch whose blast radius is meant to be one library and its callers.
`bin/fm-teardown.sh` and `bin/fm-remote-entrypoint.sh` also still read `ps -o` directly, for the same reason.
