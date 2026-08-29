# Windows (Git Bash) support: what a full measurement found, and four PRs that fix most of it

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
| **FAIL**, fixed by the four PRs | line endings at checkout, harness ancestry (`ps -o`), `kill -0` on native pids, the herdr socket path shape, MSYS argument path conversion, the crewmate pane shell, pane cwd tracking |
| **FAIL**, cross-cutting, no patch proposed | POSIX mode privacy checks on `noacl` mounts (33 of 151 `bin/*.sh`) |

The full ledger, with the exact command and output behind every row, is in [`docs/windows/measurement.md`](../measurement.md) on the fork.

## The four PRs

Each is cut from `main` at `f66be0f`, each keeps macOS and Linux byte-identical, and each carries its own test that exercises the Windows branch from a POSIX host by faking the userland.
The bodies are written out at [`pr-1.md`](pr-1.md), [`pr-2.md`](pr-2.md), [`pr-3.md`](pr-3.md), [`pr-4.md`](pr-4.md); the branch-to-commit map is in [`prs.md`](../prs.md).

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

**PR-4, the crewmate pane.**
herdr's `default_shell` on Windows is `pwsh`, `tab create` has no shell flag, and inside a pwsh pane `exec` is not a command and bare `bash` is WSL's.
Separately, `pane get .foreground_cwd` is always `null` on the Windows build - the one failure in the real-herdr smoke test - while `.cwd` is live and is fed by the shell emitting `ESC]9;9;<path>ESC\` at each prompt.
This PR routes every tab creation through one funnel that launches Git Bash by full path and carries an OSC 9;9 emitter in through `--env PROMPT_COMMAND`, and falls back to `.cwd` when `.foreground_cwd` is null.
The acceptance test was a live one: `treehouse get` inside that Git Bash pane, with the pane's own `.cwd` landing in the worktree.

The real-herdr smoke test went from 14/15 to 16/16 across PR-3 and PR-4.
The two portable-parallel lanes went from 11 green / 12 red / 1 gate-skip of 24 to 19 green / 4 red / 1 gate-skip, over the whole port.

## What happened when the whole thing was run

With the four patches applied, a real captain session drove the full loop on this machine, in a herdr tab, steered only through `pane send-text`: register a project, clone it, brief and spawn a crewmate into a treehouse worktree on the herdr backend, answer its trust dialog, let it work, take its PR, merge on the captain's word, tear down and return the worktree.
Twice, against a private sandbox repository with one deliberately failing test.
Both PRs landed green.

Four things came out of that which the subsystem-by-subsystem measurement had not:

1. **A hook cannot tell which session it belongs to on Windows.**
   Claude Code starts a hook through an intermediate process that has already exited when the hook body runs, so `Get-Process().Parent` is null and `Win32_Process.ParentProcessId` names a dead pid; the ancestry walk returns one row.
   `fm_session_lock_owned_by_self` is therefore never true inside a hook, and `bin/fm-claude-stop-autoarm.sh` exits 0 at its identity gate on every firing.
   Tokenless watcher continuity does not work on Windows, and the first mate has to arm the watcher by hand at each turn end.
   The same script run from an ordinary Bash tool call in the same session claims its generation normally, which is what isolates the cause.
   The fix has to be an identity that survives the parent - the Stop payload's own `session_id`, recorded beside the pid in `state/.lock`, would be stronger than an ancestry walk everywhere, not just here.
   That is a change to a security-relevant predicate, so it is written down rather than patched.
2. **`git rev-parse --show-toplevel` and `pwd -P` disagree on Windows** (`C:/...` versus `/c/...`), and six sites compare them to each other.
   The visible effect is that `bin/fm-fleet-sync.sh` skips every project clone, so a merged PR never reaches the local copy.
3. **The guarded merge cannot run**, because it insists on a PR poll that the mode-600 question above stops from being registered.
4. **`/bearings` said `Unknown command`** because the one tracked symlink in the repository had been checked out as a text file, which is the `core.symlinks` finding in PR-1's body.

There is a fifth, provisional: `fm_wake_identity` uses `/proc/<pid>/stat` field 22 with a comment saying that field is immune to wall-clock steps.
It is on Linux; on Cygwin it is derived from `btime` and a suspend/resume moves it for every pid at once, which made a live lock-holding watcher look dead here.

## What the four PRs do not fix

**One known defect inside PR-3's area, named so it is not rediscovered.**
A native `jq.exe` opens stdout in text mode, so a `jq -r` read that returns multiple rows carries an interior CR.
The adapter's workspace-ambiguity refusal renders `w1\r w7`, which looks correct on a terminal and matches nothing.
Nine of the adapter's 62 `jq -r` reads are multi-row; the fix is one funnel with those nine moved onto it, and it belongs as a follow-up commit on PR-3 rather than a fifth branch.

**The cross-cutting one, which is a decision rather than a patch.**
Every Git Bash mount is `noacl`, so POSIX modes are not representable: `mkdir -m 700` creates a 755 directory *and exits 1*, and `chmod 600` reads back 644.
33 of 151 `bin/*.sh` create or assert mode-700/600 private state, and every one of those checks misfires.
That is three of the four still-red test scripts, and it is what stops `fm-pr-check.sh` from preparing a PR poll at all.
A process-local `mount -o binary,posix=0,acl` made `mkdir -m 700` succeed with `stat` reporting 700 and the mode was inherited by a child bash, so a per-machine `/etc/fstab` mount is one real option; a shared "is this state private" helper with a platform-aware answer is the other.
The second is upstream's to design, and this is the question I would most like an opinion on before writing it.

## Also on the fork, held back deliberately

These are measured and tested, but they are not part of the four patches and bundling them would make each harder to review.
Each is a candidate for its own small PR if it is wanted.

- **The two PreToolUse guards.**
  Three independent Windows-only fail-opens left the watcher seatbelt completely inert: `bin/fm-arm-command-policy.mjs` imports `node:path`'s platform default, which on Windows normalizes `bin/fm-watch-arm.sh` to a backslash form that matches no protected identity, so every protected watcher command was allowed through all five harness entry forms.
  The other two are the `jq` CRLF above reaching the classifier's input, and an MSYS argument-conversion false-deny.
  This is a security defect rather than a portability one and is the strongest candidate for a fifth PR.
- **Four platform-neutral bug fixes that Windows only made visible.**
  `sha256sum "$f" | awk '{print $1}'` returns `\<digest>` when the path contains a backslash, because coreutils escapes the line and marks it with a leading backslash - so every install helper's checksum verification fails under any `RUNNER_TEMP` on a Windows runner, and would fail on a POSIX path with a backslash in it too.
  `fm_herdr_lab_cancel_provision` killed a wrapper shell rather than the server, because bash does not exec-optimize a backgrounded *function* call - a leaked `herdr server` on every platform since that function was written.
  A CRLF probe written as `grep -q $'\r$'` is always false on Git for Windows, whose `grep`, `sed` and `awk` are all patched to drop a trailing CR before matching.
  And four test fixtures built from `\uHHHH` escapes assert on literal escape text wherever `LANG` is not a UTF-8 locale, which includes a bare Linux container as much as Git Bash.
- **A `windows-latest` CI lane** running `bin/fm-lint.sh` and both portable parallel shards under Git Bash, as the count to beat.
  Worth knowing before adopting it: the full `CI=true bin/fm-lint.sh` needs a 60-minute cap there, and the slow part is ShellCheck's cross-file `--external-sources` analysis rather than spawn tax.

## What I am asking for

A read of PR-1 first, since nothing downstream is reviewable without it, and then PR-2, PR-3 and PR-4 in any order (PR-4 is stacked on PR-3; the other three are independent).
An opinion on the mode-700 question above.
And a yes or no on whether the guard fixes and the four platform-neutral fixes are wanted as further PRs, or whether you would rather they stayed on the fork.

Happy to rebase, split further, or drop any of it.
