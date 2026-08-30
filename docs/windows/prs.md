# The four upstream branches

Phase B's work lives on the `windows` integration branch as one commit per slice.
This file is the map from that integration history to the four branches a reviewer at `kunchenguid/firstmate` would actually receive.

Every branch is cut from `upstream/main` at `f66be0f8f7f56f78d09458d909bdd555b9dbcf76` (`fix(pi): restore Pi 0.84.4 renderer compatibility (#3261)`), which is the same base the integration branch uses.
All four are pushed to `origin` (`EvanBatten/firstmate-for-windows`) only.
Nothing has been pushed to `upstream` and no pull request has been opened; that is the captain's to send.

The body each of these branches would carry is written out in [upstream/pr-1.md](upstream/pr-1.md), [pr-2.md](upstream/pr-2.md), [pr-3.md](upstream/pr-3.md) and [pr-4.md](upstream/pr-4.md).

## The map

| Branch | Head | Commits | Diff from `upstream/main` | Comes from |
| --- | --- | --- | --- | --- |
| `pr-1-gitattributes` | `0fd5857` | `0fd5857` check every file out with LF so the scripts run under Git Bash | 1 file, +5 | `bb7c412` |
| `pr-2-proc-lib` | `94ddb42` | `eb2e3d1` put process identity and liveness behind one library<br>`94ddb42` teach the process library about process groups and use it in three more callers | 14 files, +991 -28 | `9286fe7` (slice 1) and the process-library paths of `0865847` (slice 6) |
| `pr-3-herdr-windows-cli` | `d15d309` | `d15d309` make the herdr adapter speak Windows paths and MSYS argument rules | 4 files, +556 -4 | `93faedd` (slice 2) |
| `pr-4-herdr-windows-pane` | `4937c52` | `d15d309` (inherited from `pr-3`)<br>`4937c52` give the crewmate a working shell and a live cwd on Windows | 6 files, +899 -12 | `7149014` (slice 3) |

`pr-4` is stacked on `pr-3` rather than cut from `upstream/main` directly.
Both change `bin/backends/herdr.sh` and `tests/fm-backend-herdr-windows.test.sh`, and the pane work reads as a diff against the CLI work, not against upstream.
The other three are independent of each other and of `pr-4`, so they can be reviewed and merged in any order; `pr-4` is the only one with a prerequisite.

`bin/fm-test-run.sh` is touched by both `pr-2` and `pr-3`, each adding one test file to the family map.
The two hunks are 61 lines apart (`@@ -205` and `@@ -266`) in different `case` arms, so the branches auto-merge cleanly against each other.

## What is in each branch

| Branch | Files |
| --- | --- |
| `pr-1-gitattributes` | `.gitattributes` |
| `pr-2-proc-lib` | `bin/fm-proc-lib.sh` (new), `bin/fm-harness.sh`, `bin/fm-session-lock-lib.sh`, `bin/fm-wake-lib.sh`, `bin/fm-procevent.sh`, `bin/fm-watch.sh`, `bin/fm-sessionstart-nudge.sh`, `bin/fm-test-run.sh`, `tests/fm-proc-lib.test.sh` (new), and the five tests that copy `fm-sessionstart-nudge.sh` into a fixture |
| `pr-3-herdr-windows-cli` | `bin/backends/herdr.sh`, `bin/backends/herdr-workspace-move.py`, `bin/fm-test-run.sh`, `tests/fm-backend-herdr-windows.test.sh` (new) |
| `pr-4-herdr-windows-pane` | `bin/backends/herdr.sh`, `docs/herdr-backend.md`, `docs/documentation-audiences.json`, `tests/fm-backend-herdr-windows.test.sh` |

The four branches touch twenty distinct paths between them.
Nineteen are byte-identical to the integration branch at `0865847` on the branch that finally carries them, checked path by path with `git diff <branch>:<path> 0865847:<path>`.
Two of those nineteen are worth naming because they are shared: `bin/backends/herdr.sh` and `tests/fm-backend-herdr-windows.test.sh` are byte-identical to slice 2 (`93faedd`) on `pr-3` and reach `0865847` identity on `pr-4`, which is exactly the shape a stacked pair should have.

The twentieth, `bin/fm-test-run.sh`, is byte-identical on **no** branch, and cannot be.
Each branch carries only its own one-line registration, while the integration copy also registers `tests/fm-guard-windows-transport.test.sh`, whose slice is in none of the four.
What is true of it instead, and is the property that matters: each branch's diff against `upstream/main` for that file is a strict subset of the integration diff, and `bin/fm-test-run.sh --check-coverage` passes on every branch, which is the check that catches a branch registering a test it does not carry or carrying one it does not register.

With that one exception named, the split loses nothing and changes nothing.

## Verification, per branch, on this machine

| Branch | Check | Result |
| --- | --- | --- |
| `pr-2-proc-lib` | `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `pr-2-proc-lib` | `shellcheck -x` on all seven changed shell files | clean |
| `pr-2-proc-lib` | `tests/fm-proc-lib.test.sh` | 15 / 15, exit 0 |
| `pr-2-proc-lib` | `tests/fm-sessionstart-nudge.test.sh` | red at case 8, the same documented Windows red as on the integration branch (node's `spawn()` cannot execute a `.sh`; see measurement.md) |
| `pr-3-herdr-windows-cli` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-3-herdr-windows-cli` | `shellcheck -x bin/backends/herdr.sh` | clean |
| `pr-3-herdr-windows-cli` | `tests/fm-backend-herdr-windows.test.sh` | 21 / 21, exit 0 |
| `pr-4-herdr-windows-pane` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-4-herdr-windows-pane` | `shellcheck -x bin/backends/herdr.sh` | clean |
| `pr-4-herdr-windows-pane` | `tests/fm-backend-herdr-windows.test.sh` | 32 / 32, exit 0 |

`pr-1-gitattributes` adds no code and has nothing to run; its effect is the checkout itself, and it is the reason every other branch's shebangs execute under Git Bash at all.

None of `pr-2`'s six test files, and neither `pr-3`'s nor `pr-4`'s, reference `fm_fakebin_link`, the `tests/lib.sh` helper that slice 4 added and that no branch carries.

## What is deliberately not in any of the four

The rest of the Windows work stays on the integration branch.
It is real and it is measured, but it is not part of the four patches the plan scoped for upstream, and bundling it would make each of them harder to review rather than easier.

| Integration-only content | Files | Why it is held back |
| --- | --- | --- |
| The two PreToolUse guard fixes (slice 4) | `bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, `bin/fm-arm-command-policy.mjs`, `bin/fm-hook-host-lib.sh`, `tests/fm-arm-pretool-check.test.sh`, `tests/fm-cd-pretool-check.test.sh`, `tests/fm-guard-windows-transport.test.sh`, `tests/lib.sh` | The strongest candidate for a fifth PR: three independent fail-opens left the watcher seatbelt inert on Windows, which is a security defect, not a portability one. It is held only because the plan scopes four PRs and the captain decides what else goes. |
| The Windows CI lane and the lint installers (slice 5) | `.github/workflows/windows-port.yml`, `bin/fm-install-*.sh`, `tests/fm-lint.test.sh`, `tests/fm-lint-workflows.test.sh`, `docs/fm-test-portable-shards.md` | The lane is this fork's count to beat and is expected red until the whole port lands. The installer changes underneath it are separable and portable (the checksum fix breaks on any POSIX path with a backslash in it), so they would be a better sixth PR than a rider on any of the four. |
| The three cross-cutting fixes from lane triage (slice 6) | `bin/fm-ensure-agents-md.sh`, `bin/fm-herdr-lab.sh`, `tests/fm-composer-lib.test.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-herdr-lab.test.sh` | Each is a genuine cross-platform bug rather than a Windows branch - notably `fm_herdr_lab_cancel_provision` orphaning the server it meant to kill on every platform - and each belongs in its own small PR against the file it fixes. |
| The port's own documents | `docs/windows/` | Working notes for this port. The evidence a reviewer needs is in the PR bodies under `docs/windows/upstream/`. |

## The one defect that was open inside `pr-3`'s area, and is now fixed

`tests/fm-backend-herdr.test.sh` was red on Windows at the workspace-ambiguity refusal, and had been since Phase A.
A native `jq.exe` writes CRLF, so a multi-row read carries an interior CR and the refusal rendered `w1\r w7` instead of `w1 w7`.

Slice 9 fixed it on the integration branch with one `fm_backend_herdr_jq_rows` funnel.
Thirteen array-iterating reads moved onto it rather than the nine predicted here: four more were masked by a `| head -1`, which reduces the answer to the single record command substitution already cleans up - a mask rather than a fix.
The suite is 181/181 on Windows and `tests/fm-backend-herdr-windows.test.sh` gained ten cases that drive the same refusal from any host through a text-mode jq fake.

It belongs on `pr-3-herdr-windows-cli` as a follow-up commit, which the re-split slice adds.
Adding a commit to a pushed branch is fine; none of these branches may be force-pushed.

## One safety note about these branches

`git checkout -b <name> upstream/main` sets the new branch's upstream to `upstream/main`, so a bare `git push` from any of them would have targeted `kunchenguid/firstmate`.
All four were re-pointed at `origin/<name>` after the first push:

```sh
git branch --set-upstream-to=origin/pr-2-proc-lib pr-2-proc-lib
```

Check `git branch -vv` before pushing from any branch cut this way.

## How to rebuild this split

```sh
git checkout -b pr-1-gitattributes upstream/main && git cherry-pick bb7c412

git checkout -b pr-2-proc-lib upstream/main
git cherry-pick -n 9286fe7            # conflicts only on docs/windows/, which is not in this branch
git rm -f docs/windows/measurement.md docs/windows/plan.html && git commit
git checkout 0865847 -- bin/fm-proc-lib.sh bin/fm-procevent.sh bin/fm-watch.sh \
  bin/fm-sessionstart-nudge.sh tests/fm-proc-lib.test.sh tests/fm-calm-pi-extension.test.sh \
  tests/fm-cursor-primary.test.sh tests/fm-opencode-primary-live-e2e.test.sh \
  tests/fm-pi-primary-live-e2e.test.sh tests/fm-sessionstart-nudge.test.sh && git commit

git checkout -b pr-3-herdr-windows-cli upstream/main
git cherry-pick -n 93faedd && git rm -f docs/windows/measurement.md docs/windows/plan.html && git commit

git checkout -b pr-4-herdr-windows-pane pr-3-herdr-windows-cli
git cherry-pick -n 7149014 && git rm -f docs/windows/measurement.md docs/windows/plan.html && git commit
```

The path-scoped `git checkout` in `pr-2` is exact rather than a shortcut: `git log --oneline upstream/main..0865847 -- <path>` shows each of those ten files is touched by slice 1 and slice 6 and by nothing else, so the file's content at `0865847` is the whole of the process-library work on it.
