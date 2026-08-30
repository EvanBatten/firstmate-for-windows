# PR-7: prove session-lock ownership when the ancestry walk is severed

Branch: `EvanBatten:pr-7-session-identity` -> `kunchenguid/firstmate:main`.
One commit on top of `pr-2-proc-lib`, 7 files, +439 -11.
**Stacked on PR-2**, which is where the process-identity walk it falls back from lives.
It also carries one `bin/fm-hook-host-lib.sh` helper shared with the guard work that is not in this set; see "One shared hunk" below.

## What is wrong today

The Stop hook may arm the watcher only from inside the session that holds `state/.lock`, and it proves that by walking its own ancestry up to a harness process.
On Git Bash that walk cannot start.

MSYS cannot implement POSIX `exec` on Windows.
It starts a **new** Win32 process, hands it the same Cygwin pid, and exits the old one, so the replacement has a Win32 parent that is already dead and an MSYS ppid of `1`.
Isolated with a native launcher so no MSYS parent can mask the effect:

```console
exec /tmp/execprobe.sh EXEC      msyspid=12251 winpid=265292  parent=NULL  msys-ppid=1
/tmp/execprobe.sh NOEXEC         msyspid=12257 winpid=291968  parent=NULL  msys-ppid=1
/tmp/execprobe.sh NOEXEC2; :     msyspid=12264 winpid=292176  parent=NULL  msys-ppid=12263
```

The middle row is the one that matters: dropping the word `exec` changes nothing, because bash exec-optimizes the **final** command of a `-c` script anyway.
Only a command that is not last keeps a live parent.
And every tracked hook entry is written in exactly that form:

```json
"command": "[ -z \"${GROK_AGENT:-}${GROK_HOOK_EVENT:-}\" ] || exit 0; exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh"
```

So `fm_harness_ancestry_pids` finds no harness at all, `fm_session_lock_owned_by_self` can never be true inside a hook, and `bin/fm-claude-stop-autoarm.sh` exits 0 at its identity gate on **every** firing.
A Windows primary never re-arms without a keypress.

This is not "how the harness starts a hook on Windows".
A throwaway project whose hooks run `probe.sh <label>` with no `exec` resolves its whole ancestry from inside all three hooks, seven hops up to `herdr.exe`, in the same live shape:

```
1780    296896  /usr/bin/bash                        bash /tmp/fm-hookprobe/probe.sh sessionstart
296896  296956  C:/Program Files/Git/bin/../usr/bin/bash
296956  294192  C:/Program Files/Git/bin/bash
294192  264860  C:/Users/ebatt/.local/bin/claude
264860  215332  .../PowerShell_7.6.5.0/pwsh
215332  0       C:/Users/ebatt/AppData/Local/Programs/herdr/herdr
```

Editing the registrations out of `exec` would be a fix that depends on an optimizer's discretion.
The identity has to stop depending on the parent instead.

## Reproducing it in three minutes

`tests/fm-claude-stop-autoarm-live-e2e.test.sh` is the opt-in credentialed regression for precisely this mechanism: real Claude Code, the real tracked hook registration, an isolated home and project.

```console
$ FM_CLAUDE_LIVE_E2E=1 bash tests/fm-claude-stop-autoarm-live-e2e.test.sh
not ok - expected exactly 2 hook-owned arm cycles, got :
```

No `state/arm-ran`, no `state/.claude-autoarm-epoch`, the model woken only by the synchronous guard's `TURN WOULD END BLIND`, two model-issued drains.

## The fix

`state/.lock` keeps its one-bare-pid format.
Fourteen readers in `bin/` and every fixture in `tests/` depend on it, and `fm_session_lock_owned_by_self` itself rejects a lock that is not purely numeric, so a second line there would make every session on every platform lock-less.

The identity goes in a sidecar `state/.lock.session` holding `<pid> <session-id>`, written by `bin/fm-lock.sh` (the single acquisition owner) inside the same claim hold that publishes the lock, and **removed** rather than left stale when the acquiring harness has no session identity.
`bin/fm-claude-stop-autoarm.sh` lifts `.session_id` out of the Stop payload it already reads and offers it as a second proof **at the identity gate only**; everything downstream is untouched.

`fm_session_lock_owned_by_session` accepts only when every one of these holds:

| Clause | Why it is there |
| --- | --- |
| the id is 8-128 chars of `[A-Za-z0-9._-]` | it is written to a state file and compared by equality |
| the sidecar is a regular non-symlink file with a `<pid> <id>` line | the same shape check `fm-lock.sh` applies to the lock |
| its pid equals the current lock pid | a pair left by an earlier session can never speak for this one |
| its id equals the id **in the payload** | read from the payload, never the environment: a watcher or background job inherits the owner's `CLAUDE_CODE_SESSION_ID`, and only the harness can deliver a Stop payload for the session |
| `fm_harness_ancestry_pids` found **no** harness at all | when the walk can name one, that answer decides, which is what leaves macOS and Linux byte-identical |
| the lock pid is still a **live** harness | otherwise the fallback would prove only that a session with this id *once* wrote the lock, and a resumed session would adopt a home nobody holds instead of going through `fm-lock.sh`'s guarded recovery |

The last two clauses came out of design review and are both load-bearing.
The fallback is reachable only in the one shape the first proof cannot answer, and only against an owner that is demonstrably still there.

### The write side, and one measured assumption

`fm_harness_session_id` reads `FM_HARNESS_SESSION_ID` if set, else `CLAUDE_CODE_SESSION_ID`.

Measured on this machine, Claude Code 2.1.251: that variable is present in every hook process **and** every Bash-tool shell, equals the payload's `session_id` for SessionStart and Stop alike, and a nested `claude -p` started from inside another session **overrides** it with its own id (outer `fddf2b81-...`, nested probe `cf40bab8-...`) rather than inheriting it.
That override is what keeps a nested session from recording the outer session's identity, so it is written into the code comment for re-verification on a harness upgrade.

The environment is the only source that covers how the lock is really acquired: `bin/fm-session-start.sh` runs `bin/fm-lock.sh`, and a Claude primary normally runs session start as a tool call rather than inside the SessionStart hook, so a payload-only write side would have recorded nothing.

It is not a documented interface.
When it disappears, no identity is found, no pair is recorded, the fallback never fires, and every platform degrades to exactly the ancestry-only behavior it has today.

## Verification

The same command that reproduced the defect, after the fix:

```
state/arm-ran               arm-run=1 pid=2528
                            arm-run=2 pid=2814
state/.claude-autoarm-epoch epoch=2 owner_pid=2620 outcome=rewake updated_at=1788059041
state/.lock                 290904
state/.lock.session         290904 72f4bae3-c833-4a72-9dd1-6eace83be8ea
```

and in the transcript, two rewake deliveries that came from the hook rather than from the guard:

```
Stop hook feedback: [... exec "$CLAUDE_PROJECT_DIR"/bin/fm-claude-stop-autoarm.sh]:
  firstmate watcher wake - one supervision event needs a handling turn now.
  stale: fixture-rapid-1
...
  stale: fixture-rapid-2
```

Two tokenless Stop-owned arm cycles, two hook-owned rewakes, three drains, zero model-issued arm commands, and the stale dead-owner lock reclaimed through session start.
Nine of the regression's ten assertions, from zero before the fix.

| Check | Result |
| --- | --- |
| `shellcheck -x` on all six changed shell files | clean |
| `tests/fm-session-lock-ancestry.test.sh`, five new cases | all nine of the suite's unit cases pass, four pre-existing and five new, driving both proofs from a faked one-row chain; the suite then stops in a fixture that cannot fork a version-named fake `claude` on this platform, identically to the integration branch |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `tests/fm-claude-stop-autoarm.test.sh` | 36 cases pass, then one pre-existing red (below), identical to the integration branch |
| `FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` | 0 -> 9 of 10 assertions (measured with PR-2 present, which this branch is stacked on) |

## The tenth assertion, which this branch does not claim

`! grep -q 'TURN WOULD END BLIND'` still fails: at the **first** Stop of a session the synchronous guard blocks once before the auto-arm has claimed.
That is a latency finding, not an identity one, and it deserves exact numbers rather than a fix guessed at here:

```
1788053788659 START guard      1788053788673 START autoarm     (14 ms apart)
1788053798790 END   guard rc=2 1788053803837 END   autoarm rc=2 (guard gave up at 10.1 s)
1788053811423 START guard      1788053811519 START autoarm
1788053813903 END   guard rc=0 1788053825764 END   autoarm rc=2 (later Stops allow in 2.4 s)
```

The auto-arm's identity proof alone costs 2130 ms (`fm_session_lock_owned_by_self`) plus 3009 ms (the fallback) in the severed-hook shape, because each ancestry walk spawns a PowerShell, and `fm_pid_alive` on a native pid costs 1.2 s because `kill -0` fails and `ps -W` scans the whole Win32 process table.
The guard's cooperation window is expressed as `SYNC_WAIT_MS / 100` iterations of a `sleep 0.1` plus one poll, which assumes a free poll; here that loop spends 5.5 s for its nominal 800 ms (about 620 ms per iteration).
Raising the budget alone would make the guard hold the turn for the better part of a minute, so the honest fix is a deadline sized from a measured time-to-claim, and that is a separate change with its own measurement.
The cost today is one forced continuation at the first Stop of a session; every later Stop is clean.

## One shared hunk

`bin/fm-hook-host-lib.sh` gains `fm_hook_payload_string`, and that is the only file in this branch that is not session-identity work.
It reads a jq field out of a hook payload and undoes a native `jq.exe`'s text-mode CRLF translation on a Windows userland, which matters because a multi-line value otherwise arrives with a stray CR before every interior newline.
Its POSIX branch is the `printf '%s' "$payload" | jq -r "$filter"` its callers already ran.

The same hunk appears in the guard work that is not in this set, byte for byte, so no reviewer ever sees two versions of one function.
Measured across all 21 pairs of these branches, the only merge conflict this branch has is with PR-5, on one line of `bin/fm-test-run.sh`'s family map that PR-2 already edits; keep both test names.

## Notes for the reviewer

`tests/fm-claude-stop-autoarm.test.sh` could not run at all on any platform before this branch: `install_autoarm_scripts` copies `fm-wake-lib.sh` but not `bin/fm-proc-lib.sh`, which PR-2 makes it source, so the hook died on `FM_PROC_UNAME: unbound variable` at the first case.
That copy, and two fixture waits raised from a 2.5 s bound to one that fits a platform where the hook needs 5 s to reach its arm, are part of this commit.

The suite then stops at one deterministic red, reproduced with the product code stashed and therefore not this branch's doing:

```
not ok - the superseded owner must exit 0 instead of double-translating: expected exit 0, got 2
```

It behaves identically on the integration branch that carries every other Windows patch, which is how we know the split did not introduce it.
