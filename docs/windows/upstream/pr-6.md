# PR-6: make the test fixtures survive a Windows host

Branch: `EvanBatten:pr-6-test-fixtures` -> `kunchenguid/firstmate:main`.
One commit, 20 files, +131 -33, entirely under `tests/`.
Depends on nothing, and nothing depends on it.
It shares one `tests/lib.sh` helper with PR-5 and with the guard work that is not in this set; see "One shared hunk" below.

## Why this exists

The 135-script portable-serial lane had never been run on a Windows host until this port.
When it was, 65 scripts came back red, and twelve of those reds traced to **four fixture assumptions**, not to the product.
Two of the four fail on Linux too.
They were invisible for eleven iterations because nothing had ever run these scripts here.

None of this branch touches `bin/`.

## The four

### 1. A Linux-shaped `PATH` literal, in sixteen scripts

Sixteen test scripts held the identical string:

```sh
RUN_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
```

The comment above most of them says the bare `PATH` is deliberate: it keeps every bootstrap probe fast and hermetic, so a fixture reports a missing tool rather than reaching the host's real `gh`/`tmux`/`tasks-axi`.
That intent is right.
The literal is not, because on Git Bash `git` and `jq` live in `/mingw64/bin` and `/c/Users/.../WinGet/Links`, and those four directories contain neither.
Every one of those fixtures reported a MISSING toolchain instead of running.

`tests/lib.sh` gains `fm_test_base_path`, and nineteen call sites across sixteen scripts read `${FM_TEST_BASE_PATH:-$(fm_test_base_path)}`, keeping the operator override they already had.

**Off MSYS it returns that same four-directory literal, byte for byte.**
On MSYS it appends the real directories of `git` and `jq`, and nothing else.

That tool set is not a judgement call, it is derived from the suite's own shape, and the first version of this patch got it wrong:

- A case that needs `git` or `jq` **absent** masks them with a `BASH_ENV` shim, which still works when their directory is on `PATH`.
- A case that needs `node` absent stages that by **deleting `node` from a fakebin**, which does not. Appending node's directory would have silently defeated that fixture.

So "which directories may a Windows widening append" is answered by asking how each tool's absence is staged, and only `git` and `jq` qualify.
The first version appended more and weakened three security-shaped assertions in the direction that lets a guarded command through; a direct end-to-end measurement of the real bootstrap under both `PATH`s is what caught it.

### 2. and 3. Two whole-`PATH` fakebins built from symlinks

`tests/fm-subagent-pretool-check.test.sh` and `tests/fm-cursor-harness.test.sh` each build a fakebin, hand it to a child as that child's **entire** `PATH`, and check that the guard fails **open** when `jq` is unavailable.

On Windows the child died at exit 127 before running a line of the script under test.
Windows resolves an MSYS executable's DLLs against the directory the image was launched from and then against `PATH`, so a symlinked `bash.exe` sitting in a fakebin that holds no `msys-2.0.dll` cannot start.
Both suites were therefore reading a correct fail-open as a fail-closed: green on Linux, red here, and testing nothing either way on a host where the shim cannot run.

Both now build the fakebin with `fm_fakebin_link`, whose POSIX branch is the `ln -s` loop they open-coded and whose MSYS branch writes an exec-by-absolute-path shim so the loader still finds the tool's own DLLs.
13/13 each.

### 4. A one-second lock hold, disproved rather than guessed

`tests/fm-watcher-lock.test.sh`'s concurrency case starts 40 contenders, has the winner `sleep 1`, and asserts exactly one winner.
On this machine it reported **two**.

That is the most alarming shape a finding can have, so it got a repro before it got a row:

| hold | contenders | winners |
| --- | --- | --- |
| the fixture's 1 s | 40 | 2 |
| 20 s | 40 | 1 |

`fm_lock_try_acquire` is correct; the fixture is a bet that forty process spawns fit inside one second, and on Windows they do not.
The winner now holds behind a **settle barrier**: it waits until all 39 rivals have recorded that their attempt finished, bounded at 60 s.
That is a deterministic condition rather than a bigger constant, and it costs a Linux run nothing, because there the barrier clears immediately.

## Verification

| Script | `upstream/main` on Windows | with this branch |
| --- | --- | --- |
| `tests/fm-watcher-lock.test.sh` | 10 cases pass, FAIL at "expected exactly one lock winner under concurrency, got 2" | **18 cases pass**, FAIL later at reused-pid recovery (needs PR-2) |
| `tests/fm-subagent-pretool-check.test.sh` | FAIL at the no-jq case | **13 / 13, exit 0** |
| `tests/fm-cursor-harness.test.sh` | FAIL at the no-jq fallback case | **13 / 13, exit 0** |

The first three rows were measured on this branch alone.
Five more were measured with the whole port applied rather than with this branch alone, so they are stated that way; each one's first failing assertion before the fix was the missing-toolchain report this branch's `PATH` helper removes:

| Script | in the portable-serial lane | with the whole port applied |
| --- | --- | --- |
| `tests/fm-secondmate-sync.test.sh` | FAIL at case 1 (52 s) | **PASS** (515 s) |
| `tests/fm-startup-memory-budget.test.sh` | FAIL at case 1 (15 s) | **PASS** (167 s) |
| `tests/fm-stow-cascade.test.sh` | FAIL (56 s) | **PASS** (59 s) |
| `tests/fm-secondmate-liveness.test.sh` | PASS | **PASS** (621 s), no regression |
| `tests/fm-vendor-auth-probe.test.sh` | PASS | **PASS** (100 s), no regression |

| Check | Result |
| --- | --- |
| `shellcheck -x` on all twenty changed files | clean |
| `bin/fm-test-run.sh --check-coverage` | `ok total=167 parallel=24 serial=131 serial_shards=4 herdr=12` |

The remaining reds in the first table are separate stories: `fm-watcher-lock`'s reused-pid recovery needs the process library in PR-2, and several other scripts in the lane fail on wall-clock budgets in the fixtures rather than on anything this branch touches.

## One shared hunk

`tests/lib.sh` gains `fm_fakebin_link` as well as `fm_test_base_path`.
The first of those is also in PR-5 and in the guard work that is not in this set, byte for byte, so no reviewer ever sees two versions of one function.
Merging this branch and PR-5 together does conflict once in `tests/lib.sh`: `fm_test_base_path` is inserted immediately after `fm_fakebin_link`, which both branches add, so the two additions share an anchor.
The conflict is add/add with an empty `ours` side, and this branch's `tests/lib.sh` is a strict superset of PR-5's, so the resolution is to take this one.

## Notes for the reviewer

The value of running the serial lane was not the count.
A suite that stops at case 37 is one red in a summary line and 36 assertions that were never reached, and twelve of the 65 reds were four fixture defects standing in front of everything behind them.

Twenty-nine of the remaining reds are wall-clock or poll-count budgets in the **test** suite: a fixed hold, a three-second deadline, a "within a poll interval or two".
Each is a bet that a process spawn is cheap, and on this machine each one loses.
The fix that generalizes is a barrier or a deadline rather than a bigger constant, which is what the lock case here demonstrates.
Those are left classified rather than changed, because each needs its own reading of what the case is actually asserting.
