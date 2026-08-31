# Windows (Git Bash) support: what a full measurement found, and seven PRs that fix most of it

Addressed to the maintainer of `kunchenguid/firstmate`.
Written on `EvanBatten/firstmate-for-windows`; nothing here has been sent, and no branch has been pushed to this repository.

## Summary

firstmate does not run on Windows today, and the first reason is not in any script: without a `.gitattributes`, a plain clone under the stock Git for Windows config checks out all 151 `bin/*.sh` with CRLF, and a shebang that ends `#!/usr/bin/env bash\r` names no interpreter.
Past that, the port is smaller than the platform's reputation suggests.
`windows-herdr-spike.yml` already found the shape of it; this is that spike carried to the end on a real machine, with a fix for each finding and a test that runs on Linux CI too.

Measured 2026-08-29 on Windows 11 26200, Git Bash 5.2.37 (MINGW64, `uname -s` = `MINGW64_NT-10.0-26200`), against `f66be0f`.
Toolchain: herdr 0.8.2 (protocol 20), treehouse 2.3.0, no-mistakes 1.57.0, Claude Code 2.1.251 (native `claude.exe`), gh 2.89, jq 1.6, node 24, shellcheck 0.11, actionlint 1.7.12.

Twenty-one subsystems were measured before the patches, and five more findings came out of running the whole thing end to end afterwards.
Of the original twenty-one: eight pass unchanged, five are degraded in ways that are already firstmate's documented fallbacks, seven fail, and one is a cross-cutting platform question that needs a decision rather than a patch.

| | Subsystems |
| --- | --- |
| **PASS**, no change needed | Claude Code hook execution, treehouse leases, herdr protocol floors, coreutils and friends, no-mistakes with a native `claude.exe`, the universal toolchain probe, symlink locks (with `MSYS=winsymlinks:nativestrict`), and the bootstrap digest itself |
| **DEGRADED**, existing fallback is correct | native event push (Windows Python has no `socket.AF_UNIX`, so the watcher polls - the same fallback the spike saw), presentation workspace ordering, stale git-lock proof (no `lsof`, so `fm-lock-lib.sh` fails safe), install helpers, wedge-alarm notifier |
| **FAIL**, fixed by these PRs | line endings at checkout, harness ancestry (`ps -o`), `kill -0` on native pids, the herdr socket path shape, MSYS argument path conversion, the crewmate pane shell, pane cwd tracking |
| **FAIL**, cross-cutting, no patch proposed | POSIX mode privacy checks on `noacl` mounts (33 of 151 `bin/*.sh`) |

The full ledger, with the exact command and output behind every row, is in [`docs/windows/measurement.md`](../measurement.md) on the fork.

## The seven PRs

Each is cut from `main` at `f66be0f`, each keeps macOS and Linux byte-identical, and each carries its own test that exercises the Windows branch from a POSIX host by faking the userland.
The bodies are written out at [`pr-1.md`](pr-1.md) through [`pr-7.md`](pr-7.md); the branch-to-commit map, including which paths each branch carries and why the two stacked ones are stacked, is in [`prs.md`](../prs.md).

**PR-1, `.gitattributes`.**
One file, five lines, four of them a comment: `* text=auto eol=lf`.
Nothing else in the port can be measured until this lands, which is why it is first.
It changes no committed bytes (the tree is already LF in the object database) and no POSIX checkout.
Its body also records the second checkout-time setting, which no repository file can express: Git for Windows ships `core.symlinks=false`, so the one tracked symlink in the repo - `.claude/skills -> ../.agents/skills` - is checked out as a 17-byte text file and Claude Code is shown zero skills.
A whole session ran that way here before `/bearings` answered `Unknown command` and gave it away.

**PR-2, `bin/fm-proc-lib.sh`.**
MSYS `ps` has no `-o`, a bash spawned by a native process reports PPID 1, and `kill -0` against a Win32 pid always says "no such process" while `ps -W` lists it.
Together those make harness ancestry unresolvable and every liveness probe answer "dead", which is the failure mode the wedge-alarm and session-lock paths are least able to tolerate.
This PR puts "what process is this, and is it alive" behind one leaf library with two branches, and moves eight callers onto it.
The POSIX branch runs literally the same `ps -o ...` and `kill -0` calls the callers ran before, character for character; the MSYS branch reads `/proc/<pid>/{ppid,pgid,winpid}` and makes at most one `Get-CimInstance` call per chain walk.
The branch is chosen by capability (does this `ps` accept `-o`?) rather than by platform, which is what keeps the eleven existing `ps`-faking tests honest on Windows instead of silently bypassing their own fixtures.

**PR-3, the herdr adapter's Windows CLI.**
Three defects, one file plus its python helper.
`fm_backend_herdr_canonical_socket_path` refuses any path that does not begin with `/`, and Windows herdr reports `C:\Users\...\herdr.sock` on *both* sides of the identity comparison, so the launcher's same-session proof refused every spawn (this is [#3283](https://github.com/kunchenguid/firstmate/issues/3283)).
MSYS rewrites `/`-leading arguments before `herdr.exe` sees them, so `send-text /clear` arrives as `C:/Program Files/Git/clear` and `--match=/x` as `--match=X:/`.
And the presentation lock's mode-700 namespace check can never hold on a `noacl` mount, so teardown printed "refusing an unlocked pane close" and could not close a pane.
The third fix is deliberately scoped to that one call site rather than swept across the other 32 mode-700 checks; see the open question below.
A second commit on the same branch adds a fourth: a native `jq.exe` opens stdout in text mode, so a `jq -r` read that returns multiple rows carries an interior CR and the adapter's workspace-ambiguity refusal rendered `w1<CR> w7`, which looks correct on a terminal and matches nothing.
Thirteen of the adapter's 61 `jq -r` reads can emit more than one record; all of them now go through one `fm_backend_herdr_jq_rows` funnel that undoes jq's record terminator on a Windows userland and runs the identical pipeline everywhere else.
That takes `tests/fm-backend-herdr.test.sh` from red at case 19 to 181 / 181 here.

**PR-4, the crewmate pane.**
herdr's `default_shell` on Windows is `pwsh`, `tab create` has no shell flag, and inside a pwsh pane `exec` is not a command and bare `bash` is WSL's.
Separately, `pane get .foreground_cwd` is always `null` on the Windows build - the one failure in the real-herdr smoke test - while `.cwd` is live and is fed by the shell emitting `ESC]9;9;<path>ESC\` at each prompt.
This PR routes every tab creation through one funnel that launches Git Bash by full path and carries an OSC 9;9 emitter in through `--env PROMPT_COMMAND`, and falls back to `.cwd` when `.foreground_cwd` is null.
The acceptance test was a live one: `treehouse get` inside that Git Bash pane, with the pane's own `.cwd` landing in the worktree.

**PR-5, `bin/fm-path-lib.sh`.**
Six sites compare a `git rev-parse --show-toplevel` answer against a `pwd -P` answer, and those two never agree on Windows: `C:/...` against `/c/...`, and they disagree about case as well.
Two of the six were live defects that fail silently, and a seventh site of the same family fails OPEN on every platform - `git rev-parse --git-path` answers absolutely in a linked worktree, so teardown's index-lock gate joined a drive-rooted path onto a directory and missed a real `index.lock`.
Another cross-platform hole closed along the way: `bash`'s `cd ""` succeeds, so an empty worktree root resolved to the caller's own current directory inside a spawn isolation guard.

**PR-6, the test fixtures.**
Nothing under `bin/`. Four fixture assumptions that made the suite unrunnable here, two of which fail on Linux too: a `/usr/bin:/bin:/usr/sbin:/sbin` `PATH` literal in sixteen scripts that contains neither `git` nor `jq` on this platform, two whole-`PATH` fakebins built from symlinks (a symlinked MSYS binary cannot load `msys-2.0.dll`, so two suites read a correct fail-open as a fail-closed), and one lock fixture that bets forty process spawns fit inside a one-second hold.
That last one is worth a sentence: it reported two winners under concurrency, which is the most alarming shape a finding can have, and forty contenders with a twenty-second hold disproved it in ninety seconds. `fm_lock_try_acquire` is correct; the fixture now holds behind a settle barrier instead of a sleep.

**PR-7, the session-lock identity.**
The Stop hook's ancestry walk returns one row on Windows, so tokenless watcher continuity does not work at all. See item 1 below for the cause, which is not what the first diagnosis said it was.
Stacked on PR-2, because its whole subject is what to do when PR-2's walk can name no harness.

The real-herdr smoke test went from 14/15 to 16/16 across PR-3 and PR-4.
The two portable-parallel lanes went from 11 green / 12 red / 1 gate-skip of 24 to 19 green / 4 red / 1 gate-skip, over the whole port.

## What happened when the whole thing was run

With the first four patches applied, a real captain session drove the full loop on this machine, in a herdr tab, steered only through `pane send-text`: register a project, clone it, brief and spawn a crewmate into a treehouse worktree on the herdr backend, answer its trust dialog, let it work, take its PR, merge on the captain's word, tear down and return the worktree.
Twice, against a private sandbox repository with one deliberately failing test.
Both PRs landed green.

Four things came out of that which the subsystem-by-subsystem measurement had not:

1. **A hook cannot tell which session it belongs to on Windows** - since fixed, and the first diagnosis was wrong in a way worth repeating.
   The ancestry walk from inside a Stop hook returns one row, so `fm_session_lock_owned_by_self` is never true and `bin/fm-claude-stop-autoarm.sh` exits 0 at its identity gate on every firing; tokenless watcher continuity simply does not work.
   The cause is not the harness: SessionStart, synchronous Stop and async Stop hooks all resolve a full chain to `claude.exe`.
   It is that MSYS cannot implement POSIX `exec` - it starts a NEW Win32 process, hands it the old Cygwin pid, and exits the original - and bash exec-optimizes the final command of a `-c` script, which is the form every tracked hook registration is written in.
   Fixed by recording the harness session id beside the pid (`state/.lock.session`) and accepting the Stop payload's `session_id` when, and only when, the ancestry walk names no harness at all.
   POSIX hosts resolve their ancestry, never reach the fallback, and decide exactly what they decided before.
   The read side must be the payload and never the environment, because a watcher or background job inherits the owner's `CLAUDE_CODE_SESSION_ID`.
2. **`git rev-parse --show-toplevel` and `pwd -P` disagree on Windows** (`C:/...` versus `/c/...`, and about case as well) - since fixed.
   Six sites compare the two forms; measured one at a time, two of them were live defects: `bin/fm-fleet-sync.sh` skipped every project clone, so a merged PR never reached the local copy, and `bin/fm-config-inherit-lib.sh` refused every inheritable config item without ever reaching `git check-ignore`.
   The same survey found a seventh site of the family that failed OPEN: `git rev-parse --git-path` answers absolutely in a linked worktree on every platform, so `bin/fm-teardown.sh` joined a drive-rooted path onto a directory and missed a real `index.lock` while git was holding the index.
   Fixed by `bin/fm-path-lib.sh`, a leaf owning the four questions, where the POSIX branch of each helper is the expression it replaced.
3. **The guarded merge cannot run**, because it insists on a PR poll that the mode-600 question above stops from being registered.
4. **`/bearings` said `Unknown command`** because the one tracked symlink in the repository had been checked out as a text file, which is the `core.symlinks` finding in PR-1's body.

There is a fifth, measured rather than guessed at and since fixed on the fork: `fm_pid_identity` uses `/proc/<pid>/stat` field 22 with a comment saying that field is immune to wall-clock steps.
It is on Linux; here `/proc/stat`'s `btime` is `now - uptime` recomputed at every read and field 22 is anchored to it, so a clock correction moves the identity of every pid at once and a live lock-holding watcher reads as dead.
`CLK_TCK` on this userland is 1000, not 100, so the sensitivity is a millisecond and an ordinary NTP resync is enough - a closed lid is not required.
The remedy is to record the absolute creation time, but not as the obvious `btime + field22/CLK_TCK`: `btime` is truncated to whole seconds while field 22 carries milliseconds, so their sum still moves by a second on a FRACTIONAL step, which is the ordinary shape of an NTP correction.
What the fork records instead, on a non-Linux `/proc` and under its own `proc-createtime` key, is that same origin at full precision - `now - uptime + field22/CLK_TCK`, floored once, `now` from bash's `EPOCHREALTIME` and `uptime` monotonic - while Linux keeps the raw field unchanged.
A fake `/proc` stepped by 3 s and by a fractional 1.25 s yields one identity; row 25 of the ledger carries the measurement and the residual that `/proc/uptime`'s centisecond granularity leaves behind.

## What these PRs do not fix

**The cross-cutting one, which is a decision rather than a patch.**
Every Git Bash mount is `noacl`, so POSIX modes are not representable: `mkdir -m 700` creates a 755 directory *and exits 1*, and `chmod 600` reads back 644.
33 of 151 `bin/*.sh` create or assert mode-700/600 private state, and every one of those checks misfires.
That is three of the four still-red test scripts, and it is what stops `fm-pr-check.sh` from preparing a PR poll at all.
A process-local `mount -o binary,posix=0,acl` made `mkdir -m 700` succeed with `stat` reporting 700 and the mode was inherited by a child bash, so a per-machine `/etc/fstab` mount is one real option; a shared "is this state private" helper with a platform-aware answer is the other.
The second is upstream's to design, and this is the question I would most like an opinion on before writing it.

## Also on the fork, held back deliberately

These are measured and tested, but they are not part of the seven branches and bundling them would make each harder to review.
Each is a candidate for its own small PR if it is wanted.

- **The two PreToolUse guards.**
  Three independent Windows-only fail-opens left the watcher seatbelt completely inert: `bin/fm-arm-command-policy.mjs` imports `node:path`'s platform default, which on Windows normalizes `bin/fm-watch-arm.sh` to a backslash form that matches no protected identity, so every protected watcher command was allowed through all five harness entry forms.
  The other two are the `jq` CRLF above reaching the classifier's input, and an MSYS argument-conversion false-deny.
  This is a security defect rather than a portability one, and it is the piece I would send first if you want anything beyond PR-1 through PR-4: two of its helpers (`fm_hook_payload_string` and a fakebin `PATH` helper) turned out to be prerequisites for PR-5, PR-6 and PR-7, which carry byte-identical copies of those hunks so that each branch stays independently green.
- **Four platform-neutral bug fixes that Windows only made visible.**
  `sha256sum "$f" | awk '{print $1}'` returns `\<digest>` when the path contains a backslash, because coreutils escapes the line and marks it with a leading backslash - so every install helper's checksum verification fails under any `RUNNER_TEMP` on a Windows runner, and would fail on a POSIX path with a backslash in it too.
  `fm_herdr_lab_cancel_provision` killed a wrapper shell rather than the server, because bash does not exec-optimize a backgrounded *function* call - a leaked `herdr server` on every platform since that function was written.
  A CRLF probe written as `grep -q $'\r$'` is always false on Git for Windows, whose `grep`, `sed` and `awk` are all patched to drop a trailing CR before matching.
  And four test fixtures built from `\uHHHH` escapes assert on literal escape text wherever `LANG` is not a UTF-8 locale, which includes a bare Linux container as much as Git Bash.
- **A `windows-latest` CI lane** running `bin/fm-lint.sh` and both portable parallel shards under Git Bash, as the count to beat.
  Worth knowing before adopting it: the full `CI=true bin/fm-lint.sh` needs a 60-minute cap there, and the slow part is ShellCheck's cross-file `--external-sources` analysis rather than spawn tax.

## What I am asking for

A read of PR-1 first, since nothing downstream is reviewable without it.
Then PR-2, PR-3, PR-5 and PR-6 in any order; PR-4 is stacked on PR-3 and PR-7 on PR-2, so those two want their base merged first.
An opinion on the mode-700 question above.
And a yes or no on whether the guard fixes and the four platform-neutral fixes are wanted as further PRs, or whether you would rather they stayed on the fork. PR-5, PR-6 and PR-7 are the ones most likely to be out of scope for you; they are separated so they can be dropped without touching the first four.

Happy to rebase, split further, or drop any of it.
