# The seven upstream branches

Phase B's work lives on the `windows` integration branch as one commit per slice.
This file is the map from that integration history to the branches a reviewer at `kunchenguid/firstmate` would actually receive.

Every branch is cut from `upstream/main` at `f66be0f8f7f56f78d09458d909bdd555b9dbcf76` (`fix(pi): restore Pi 0.84.4 renderer compatibility (#3261)`), which is the same base the integration branch uses.
Two are stacked rather than cut directly: `pr-4` on `pr-3`, and `pr-7` on `pr-2`.
All are pushed to `origin` (`EvanBatten/firstmate-for-windows`) only.
Nothing has been pushed to `upstream` and no pull request has been opened; that is the captain's to send.

The body each branch would carry is written out in [upstream/pr-1.md](upstream/pr-1.md) through [pr-7.md](upstream/pr-7.md).

## The map

| Branch | Head | Commits | Diff | Comes from |
| --- | --- | --- | --- | --- |
| `pr-1-gitattributes` | `0fd5857` | `0fd5857` check every file out with LF so the scripts run under Git Bash | 1 file, +5 | `bb7c412` |
| `pr-2-proc-lib` | `8f955a5` | `eb2e3d1` put process identity and liveness behind one library<br>`94ddb42` teach the process library about process groups and use it in three more callers<br>`8f955a5` copy the process library into the fixtures that install the wake one | 17 files, +1002 -30 | `9286fe7` (slice 1), the process-library paths of `0865847` (slice 6), and the three fixture-installer hunks of `cd45ebf` (slice 11) |
| `pr-3-herdr-windows-cli` | `50ebb49` | `d15d309` make the herdr adapter speak Windows paths and MSYS argument rules<br>`50ebb49` read every multi-row jq answer through one CRLF-tolerant reader | 5 files, +956 -26 | `93faedd` (slice 2) and `4fa7688` (slice 9) |
| `pr-4-herdr-windows-pane` | `64b1dff` | `4937c52` give the crewmate a working shell and a live cwd on Windows<br>`64b1dff` merge the jq CRLF reader up from pr-3 | 4 files, +339 -9 **against `pr-3`**; 6 files, +1294 -34 against `upstream/main` | `7149014` (slice 3) |
| `pr-5-path-lib` | `b483948` | `b483948` compare worktree paths through one library instead of six spellings | 10 files, +634 -32 | `1412bf3` (slice 10) |
| `pr-6-test-fixtures` | `863c412` | `863c412` make the test fixtures survive a Windows host | 20 files, +131 -33 | the `tests/` remainder of `cd45ebf` (slice 11) |
| `pr-7-session-identity` | `734ce62` | `734ce62` prove session-lock ownership when the ancestry walk is severed | 7 files, +439 -11 **against `pr-2`** | `d80757f` (slice 8) |

`pr-4` is stacked on `pr-3` because both change `bin/backends/herdr.sh` and `tests/fm-backend-herdr-windows.test.sh`, and the pane work reads as a diff against the CLI work rather than against upstream.
`pr-7` is stacked on `pr-2` because its whole subject is what to do when `pr-2`'s ancestry walk returns one row.
The other five are independent of each other and can be reviewed and merged in any order.

`bin/fm-test-run.sh` is touched by `pr-2`, `pr-3` and `pr-5`, each adding one test file to the family map.
`pr-2` and `pr-5` edit the SAME physical line of the same alternation list, so those two conflict; see the merge matrix below.

## What is in each branch

| Branch | Files |
| --- | --- |
| `pr-1-gitattributes` | `.gitattributes` |
| `pr-2-proc-lib` | `bin/fm-proc-lib.sh` (new), `bin/fm-harness.sh`, `bin/fm-session-lock-lib.sh`, `bin/fm-wake-lib.sh`, `bin/fm-procevent.sh`, `bin/fm-watch.sh`, `bin/fm-sessionstart-nudge.sh`, `bin/fm-test-run.sh`, `tests/fm-proc-lib.test.sh` (new), the five tests that copy `fm-sessionstart-nudge.sh` into a fixture, and the three fixture installers that copy `fm-wake-lib.sh` |
| `pr-3-herdr-windows-cli` | `bin/backends/herdr.sh`, `bin/backends/herdr-workspace-move.py`, `bin/fm-test-run.sh`, `docs/herdr-backend.md`, `tests/fm-backend-herdr-windows.test.sh` (new) |
| `pr-4-herdr-windows-pane` | `bin/backends/herdr.sh`, `docs/herdr-backend.md`, `docs/documentation-audiences.json`, `tests/fm-backend-herdr-windows.test.sh` |
| `pr-5-path-lib` | `bin/fm-path-lib.sh` (new), `bin/fm-brief.sh`, `bin/fm-config-inherit-lib.sh`, `bin/fm-control.sh`, `bin/fm-fleet-sync.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-test-run.sh`, `tests/fm-path-lib.test.sh` (new), `tests/lib.sh` |
| `pr-6-test-fixtures` | `tests/lib.sh` and nineteen test scripts |
| `pr-7-session-identity` | `bin/fm-session-lock-lib.sh`, `bin/fm-claude-stop-autoarm.sh`, `bin/fm-lock.sh`, `bin/fm-hook-host-lib.sh`, `docs/watcher-continuity.md`, `tests/fm-claude-stop-autoarm.test.sh`, `tests/fm-session-lock-ancestry.test.sh` |

## Nothing drifted, and every difference is named

Every path a branch carries was diffed against the integration branch at `cd45ebf`, path by path, with `git diff cd45ebf <branch> -- <path>`.
Everything is byte-identical except the following, and each exception is a consequence of the split rather than a drift:

| Branch | Path | Why it differs from `cd45ebf` |
| --- | --- | --- |
| all but `pr-1`, `pr-6` | `bin/fm-test-run.sh` | each branch registers only the test file it carries; the integration copy registers all of them plus `tests/fm-guard-windows-transport.test.sh`, whose slice is in none of these branches |
| `pr-2` | `bin/fm-session-lock-lib.sh` | the integration copy also has `pr-7`'s session-identity section |
| `pr-2`, `pr-7` | `tests/fm-turnend-guard.test.sh` | the integration copy also has the two fakebin conversions that belong to the guard work held back below |
| `pr-2`, `pr-6`, `pr-7` | `tests/fm-sessionstart-nudge.test.sh` | `pr-2` has the process-library hunk and `pr-6` has the base-`PATH` hunk; the integration copy has both |
| `pr-3` | `bin/backends/herdr.sh`, `docs/herdr-backend.md`, `tests/fm-backend-herdr-windows.test.sh` | the integration copy also has `pr-4`'s pane work; `pr-4` reaches byte identity on all three |
| `pr-4` | `docs/documentation-audiences.json` | the integration copy also registers `docs/windows/README.md` and `docs/windows/measurement.md`, which no branch carries |
| `pr-5` | `tests/lib.sh` | the integration copy also has `pr-6`'s `fm_test_base_path` |

`bin/fm-test-run.sh --check-coverage` passes on every branch, which is the check that catches a branch registering a test it does not carry or carrying one it does not register.

## Three helpers are shared, on purpose

Three branches carry a helper that is not their own subject.
Each copy is byte-identical to the integration branch's, so no reviewer ever sees two versions of one function.

| Helper | File | Carried by | Also belongs to |
| --- | --- | --- | --- |
| `fm_fakebin_link` | `tests/lib.sh` | `pr-5`, `pr-6` | the guard work (slice 4), held back |
| `fm_test_base_path` | `tests/lib.sh` | `pr-6` | nothing else |
| `fm_hook_payload_string` | `bin/fm-hook-host-lib.sh` | `pr-7` | the guard work (slice 4), held back |

This was not chosen for convenience; it was measured.
`tests/fm-path-lib.test.sh` fails at its mount-shadowing case without `fm_fakebin_link`, because that case hands its child a curated `PATH` containing `cygpath`.
`bin/fm-claude-stop-autoarm.sh` cannot read `.session_id` out of the Stop payload without `fm_hook_payload_string`.

The alternative was a four-deep stack rooted at the guard work, which would have made each of these branches unreviewable on its own.
If the captain sends the guard work first, `pr-5`, `pr-6` and `pr-7` each carry that hunk already and there is nothing to resolve on those lines.

## The merge matrix, measured

`git merge-tree --write-tree A B` was run for all 21 pairs.
Eighteen are clean; three are not, and each has a one-line resolution.
This disproves the first version of the paragraph above, which claimed identical additions always merge in any order: they do, but an addition that lands at the SAME ANCHOR as another branch's different addition does not.

| Pair | File | Why | Resolution |
| --- | --- | --- | --- |
| `pr-2` + `pr-5` | `bin/fm-test-run.sh` | both edit the line `fm-operational-input.test.sh\|fm-pi-primary-types.test.sh\|` in the family map: `pr-2` appends `fm-proc-lib.test.sh`, `pr-5` splits the line to insert `fm-path-lib.test.sh` | keep both names |
| `pr-5` + `pr-7` | `bin/fm-test-run.sh` | `pr-7` inherits `pr-2`'s hunk | same |
| `pr-5` + `pr-6` | `tests/lib.sh` | `pr-6`'s `fm_test_base_path` is inserted immediately after `fm_fakebin_link`, which both branches add, so the two additions share an anchor. The conflict is add/add with an EMPTY `ours` side | take the incoming block; `pr-6`'s `tests/lib.sh` is a strict superset of `pr-5`'s |

Everything else, including `pr-2` + `pr-3`, `pr-3` + `pr-5`, `pr-6` + `pr-7` and every pair involving `pr-1` or `pr-4`, merges clean.

## Verification, per branch, on this machine

| Branch | Check | Result |
| --- | --- | --- |
| `pr-2-proc-lib` | `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `pr-2-proc-lib` | `shellcheck -x` on every changed shell file | clean |
| `pr-2-proc-lib` | `tests/fm-proc-lib.test.sh` | 15 / 15, exit 0 |
| `pr-2-proc-lib` | `tests/fm-afk-return.test.sh`, before / after the third commit | red at case 1 / **all cases pass** |
| `pr-2-proc-lib` | `tests/fm-turnend-guard.test.sh`, before / after the third commit | 7 cases reached / **30 cases reached**, then the fakebin case that needs `pr-6`'s helper |
| `pr-2-proc-lib` | `tests/fm-sessionstart-nudge.test.sh` | red at case 8, the same documented Windows red as on the integration branch |
| `pr-3-herdr-windows-cli` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-3-herdr-windows-cli` | `shellcheck -x bin/backends/herdr.sh` and the new test | clean |
| `pr-3-herdr-windows-cli` | `tests/fm-backend-herdr-windows.test.sh` | 32 / 32, exit 0 |
| `pr-3-herdr-windows-cli` | `tests/fm-backend-herdr.test.sh` (the adapter's unit suite) | **181 / 181, exit 0**, from red at case 19 before the second commit |
| `pr-4-herdr-windows-pane` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-4-herdr-windows-pane` | `shellcheck -x bin/backends/herdr.sh` and the new test | clean |
| `pr-4-herdr-windows-pane` | `tests/fm-backend-herdr-windows.test.sh` | 43 / 43, exit 0 |
| `pr-5-path-lib` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-5-path-lib` | `shellcheck -x` on all nine changed shell files | clean |
| `pr-5-path-lib` | `tests/fm-path-lib.test.sh` | 14 / 14, exit 0 |
| `pr-6-test-fixtures` | `bin/fm-test-run.sh --check-coverage` | `ok total=167 parallel=24 serial=131 serial_shards=4 herdr=12` (upstream's own count; this branch adds no test file) |
| `pr-6-test-fixtures` | `shellcheck -x` on all twenty changed files | clean |
| `pr-6-test-fixtures` | `tests/fm-watcher-lock.test.sh`, `upstream/main` / this branch | 10 cases then "got 2 winners" / **18 cases**, then reused-pid recovery, which needs `pr-2` |
| `pr-6-test-fixtures` | `tests/fm-subagent-pretool-check.test.sh`, `tests/fm-cursor-harness.test.sh` | 13 / 13 each, exit 0 |
| `pr-7-session-identity` | `bin/fm-test-run.sh --check-coverage` | same `ok` line |
| `pr-7-session-identity` | `shellcheck -x` on all six changed shell files | clean |
| `pr-7-session-identity` | `tests/fm-session-lock-ancestry.test.sh` | 9 cases pass, then the same fork-failure red the integration branch has |
| `pr-7-session-identity` | `tests/fm-claude-stop-autoarm.test.sh` | 36 cases pass, then the same deterministic red the integration branch has |

`pr-1-gitattributes` adds no code and has nothing to run; its effect is the checkout itself, and it is the reason every other branch's shebangs execute under Git Bash at all.

Both of `pr-7`'s reds were checked against the integration branch in a worktree at `cd45ebf` rather than assumed: both suites stop at the identical assertion there, so the split did not introduce them.
`tests/fm-session-lock-ancestry.test.sh` stops on `dofork: child -1 - CreateProcessW failed`, an MSYS fork failure in a fixture that spawns a version-named fake `claude`, in both places.

## What is deliberately not in any branch

The rest of the Windows work stays on the integration branch.
It is real and it is measured, but bundling it would make each of these harder to review rather than easier.

| Integration-only content | Files | Why it is held back |
| --- | --- | --- |
| The two PreToolUse guard fixes (slice 4) | `bin/fm-arm-pretool-check.sh`, `bin/fm-cd-pretool-check.sh`, `bin/fm-arm-command-policy.mjs`, `bin/fm-hook-host-lib.sh`, `tests/fm-arm-pretool-check.test.sh`, `tests/fm-cd-pretool-check.test.sh`, `tests/fm-guard-windows-transport.test.sh`, `tests/lib.sh` | Three independent fail-opens left the watcher seatbelt inert on Windows, which is a security defect rather than a portability one, and it deserves its own review. Two of its helpers are now measurably prerequisites for `pr-5`, `pr-6` and `pr-7`, so if the captain sends anything else from this set, this is the one to send first. |
| The Windows CI lane and the lint installers (slice 5) | `.github/workflows/windows-port.yml`, `bin/fm-install-*.sh`, `tests/fm-lint.test.sh`, `tests/fm-lint-workflows.test.sh`, `docs/fm-test-portable-shards.md` | The lane is this fork's count to beat and is expected red until the whole port lands. The installer changes underneath it are separable and portable (the checksum fix breaks on any POSIX path with a backslash in it), so they would be a better PR of their own than a rider on any of these. |
| The three cross-cutting fixes from lane triage (slice 6) | `bin/fm-ensure-agents-md.sh`, `bin/fm-herdr-lab.sh`, `tests/fm-composer-lib.test.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-herdr-lab.test.sh` | Each is a genuine cross-platform bug rather than a Windows branch - notably `fm_herdr_lab_cancel_provision` orphaning the server it meant to kill on every platform - and each belongs in its own small PR against the file it fixes. |
| The port's own documents | `docs/windows/` | Working notes for this port. The evidence a reviewer needs is in the PR bodies under `docs/windows/upstream/`. |

## One safety note about these branches

`git checkout -b <name> upstream/main` and `git worktree add -b <name> ... upstream/main` both set the new branch's upstream to `upstream/main`, so a bare `git push` from any of them would have targeted `kunchenguid/firstmate`.
Every branch is re-pointed at `origin/<name>` after its first push:

```sh
git branch --set-upstream-to=origin/pr-5-path-lib pr-5-path-lib
```

Check `git branch -vv` before pushing from any branch cut this way.
None of these branches may be force-pushed; the follow-up work on `pr-2`, `pr-3` and `pr-4` arrived as additional commits, and `pr-4` picked `pr-3`'s follow-up up through a merge rather than a rebase for exactly that reason.

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
git checkout cd45ebf -- tests/fm-afk-return.test.sh tests/fm-remote-backlog-handoff.test.sh
# tests/fm-turnend-guard.test.sh: apply only the two fm-proc-lib.sh copy hunks by hand
git commit

git checkout -b pr-3-herdr-windows-cli upstream/main
git cherry-pick -n 93faedd && git rm -f docs/windows/measurement.md docs/windows/plan.html && git commit
git cherry-pick -n 4fa7688            # see "not a straight cherry-pick" below
git rm -f docs/windows/measurement.md docs/windows/plan.html docs/windows/prs.md   docs/windows/upstream/issue.md docs/windows/upstream/pr-3.md
# resolve the three add/add conflicts by keeping ONLY the funnel's lines
git commit

git checkout -b pr-4-herdr-windows-pane pr-3-herdr-windows-cli   # at d15d309
git cherry-pick -n 7149014 && git rm -f docs/windows/measurement.md docs/windows/plan.html && git commit
git merge --no-ff pr-3-herdr-windows-cli
git checkout 4fa7688 -- bin/backends/herdr.sh docs/herdr-backend.md \
  tests/fm-backend-herdr-windows.test.sh && git commit

git worktree add -b pr-5-path-lib <dir> upstream/main
git checkout cd45ebf -- bin/fm-brief.sh bin/fm-config-inherit-lib.sh bin/fm-control.sh \
  bin/fm-fleet-sync.sh bin/fm-path-lib.sh bin/fm-spawn.sh bin/fm-teardown.sh \
  tests/fm-path-lib.test.sh
git checkout 5d1e2ce -- tests/lib.sh    # fm_fakebin_link, the shared prerequisite
# bin/fm-test-run.sh: add fm-path-lib.test.sh to the family map by hand
git commit

git worktree add -b pr-6-test-fixtures <dir> upstream/main
git checkout cd45ebf -- tests/lib.sh <the nineteen other tests/ paths of cd45ebf,
                                      minus fm-afk-return and fm-remote-backlog-handoff>
# tests/fm-sessionstart-nudge.test.sh: apply only the RUN_PATH hunk by hand
git commit

git checkout -b pr-7-session-identity pr-2-proc-lib
git checkout cd45ebf -- bin/fm-claude-stop-autoarm.sh bin/fm-lock.sh \
  bin/fm-session-lock-lib.sh bin/fm-hook-host-lib.sh docs/watcher-continuity.md \
  tests/fm-claude-stop-autoarm.test.sh tests/fm-session-lock-ancestry.test.sh
git commit
```

The path-scoped `git checkout`es are exact rather than shortcuts: `git log --full-history upstream/main..cd45ebf -- <path>` shows, for each of those paths, exactly which slices touch it, and in every case above that set is the slices the branch carries.
The three paths where it is not (`tests/fm-sessionstart-nudge.test.sh`, `tests/fm-turnend-guard.test.sh`, `tests/lib.sh`) are the three the recipe patches by hand.

### The jq follow-up is not a straight cherry-pick

`git cherry-pick 4fa7688` onto `pr-3` reports content conflicts in all three of its files, and they are add/add rather than real disagreements: the funnel is inserted at exactly the anchor `pr-4`'s pane work occupies, so `theirs` presents the funnel and the pane block together while `ours` is empty.
Taking `theirs` wholesale silently re-imports the pane work into `pr-3`.
The resolution is to keep only the funnel's own lines in each file: 52 lines in `bin/backends/herdr.sh`, one documentation section, and eleven cases plus eleven runner lines in the test.

The same fact is why `pr-4` picks the follow-up up with a merge whose resolution is `git checkout 4fa7688 -- <the three files>`: on `pr-4` the union of both sides IS the integration content, so the merge lands on byte identity.
