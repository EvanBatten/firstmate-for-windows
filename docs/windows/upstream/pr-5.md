# PR-5: compare worktree paths through one library instead of six spellings

Branch: `EvanBatten:pr-5-path-lib` -> `kunchenguid/firstmate:main`.
One commit, 10 files, +634 -32, of which +512 is the new library and its test.
Depends on nothing.
It shares one `tests/lib.sh` helper with the guard work that is not in this set; see "One shared hunk" below.

## What is wrong today

Six places in `bin/` ask "is this the same directory?" or "is this path inside that one?", and they build the two sides with two different tools:
`git rev-parse --show-toplevel` on one side, `pwd -P` on the other.
On macOS and Linux those two agree often enough that nobody noticed.
On a Windows userland they never agree, because they answer in different namespaces:

```console
$ cd /c/Users/ebatt/firstmate-gnhf
$ git rev-parse --show-toplevel
C:/Users/ebatt/firstmate-gnhf
$ pwd -P
/c/Users/ebatt/firstmate-gnhf
```

Two of the six are live defects rather than latent ones, and both fail silently:

| site | what breaks | observed |
| --- | --- | --- |
| `bin/fm-fleet-sync.sh` clone-root gate | `git top = pwd -P` is never true | **every project clone is skipped** |
| `bin/fm-config-inherit-lib.sh` `destination_allows_inherited_item` | `case "$dest_path" in "$top"/*)` never matches | **every inheritable config item is refused** |

The second one never reaches `git check-ignore` at all, so a secondmate home inside a work tree inherits nothing and reports every item skipped, with no error anywhere.

A third defect found while wiring the helper is **not** Windows-specific and is the reason this branch is worth taking on a POSIX-only fleet:

```console
$ cd /tmp/row23repro/repo && git rev-parse --git-path index.lock
.git/index.lock
$ cd /tmp/row23repro/wt   && git rev-parse --git-path index.lock
/tmp/row23repro/repo/.git/worktrees/wt/index.lock
```

`git rev-parse --git-path` answers **relatively** in a plain clone and **absolutely** in a linked worktree, and every worktree `bin/fm-teardown.sh` tears down is a linked one.
`bin/fm-teardown.sh`'s `worktree_git_lock_path` tests `case "$lock" in /*)` and joins anything else onto the worktree directory.
Where the `.git` layout makes git answer absolutely with a leading spelling the case arm does not match, the join produces a path that can never exist, `worktree_safety_blocked_by_lock` reports "no lock" for a worktree whose index git is holding, and teardown proceeds to inspect and return it.
That is a fail-**open** in a gate whose entire job is to refuse while the answer is unreadable.
`bin/fm-fleet-sync.sh`'s `packed_refs_lock_path` has the identical shape and gets the identical one-line fix; there `$PROJ` is a clone root, so it is latent rather than live.

A fourth, also cross-platform: `bash`'s `cd ""` **succeeds** and leaves the shell where it was.
`wt_top_real=$(cd "$wt_top" 2>/dev/null && pwd -P)` in `bin/fm-spawn.sh` therefore resolved an empty worktree root to the **caller's own current directory**, and the isolation guard compared that against itself.

## The fix

`bin/fm-path-lib.sh` is a leaf: it sources nothing, has no side effects on source, and is sourced by five scripts.
Four functions, and **the POSIX branch of each is the expression it replaces**:

| function | macOS/Linux | added on a Windows userland |
| --- | --- | --- |
| `fm_path_is_absolute` | `case "$p" in /*)` | also a drive root, `C:/x` or `C:\x` |
| `fm_path_canon_dir` | `(cd "$p" 2>/dev/null && pwd -P)` | a `cygpath -m` round trip that pins the mount spelling |
| `fm_path_dirs_equal` | `[ "$a" = "$b" ]` | a case-folded retry, only after `=` has already failed |
| `fm_path_strip_dir_prefix` | `case "$p" in "$d"/*)` plus `${p#"$d"/}` | a case-folded prefix **test**, with the answer's own case kept |

The gate is whether `cygpath` is on `PATH`, the same marker `bin/backends/herdr.sh` uses for the same question about socket paths.
That is a property of the userland rather than of `uname`, which is what actually decides whether `C:/x` is an absolute path or a relative one containing a colon.
It is probed per call (`command -v` is a builtin, no fork), which is also what makes both branches reachable from either host with nothing faked but `PATH`.

Two deliberate non-symmetries, both of which only ever refuse more:

- `fm_path_canon_dir` refuses an **empty** argument on every platform. That is the `cd ""` hole above.
- `fm_path_canon_dir` and `fm_path_strip_dir_prefix` never fold case in their **answers**, only in their comparisons. Their answers are real paths handed to `git check-ignore` and to `cd`; folding belongs to the comparison, never to the value.

`fm_path_dirs_equal` deliberately does not canonicalize either.
A caller that has not reduced both sides is asking the wrong question, and giving it a plausible answer would hide that.

### What the acceptance review corrected

The first version of `fm_path_canon_dir` was `(cd "$p" 2>/dev/null && pwd -P)` on every platform, on the reasoning that `cd` accepts a drive root and `pwd -P` answers in the shell's own namespace, so no Windows branch was needed.
A measurement disproved it: `pwd -P` picks the **most specific** mount, and where a mount table overlaps, two spellings of one directory both survive `cd`-then-`pwd -P`.
The shipped version pins the mount spelling through `cygpath -m` on the Windows branch, which is why `tests/fm-path-lib.test.sh` has a shadowed-mount case at all.

## Verification

| Check | Result |
| --- | --- |
| `shellcheck -x` on all nine changed shell files | clean |
| `tests/fm-path-lib.test.sh` (new, 14 cases) | 14 / 14, exit 0, on Windows |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `fm-fleet-sync` clone-root gate, before / after | `SKIPPED (not a clone root)` / `accepted (clone root recognised)` |
| the safety property that gate exists for, after | a directory merely nested in a repo is still `SKIPPED` |
| `destination_allows_inherited_item`, before / after | gitignored destination `REFUSED (1)` / `ALLOWED (0)`; a non-gitignored destination is still `REFUSED (1)` |
| `worktree_git_lock_path` in a linked worktree, before / after | lock **missed** / lock **seen**; the plain-clone answer is unchanged |

`tests/fm-path-lib.test.sh` fakes `cygpath` and a shadowed mount, so **both branches run on Linux and macOS CI too**.

## One shared hunk

`tests/lib.sh` gains `fm_fakebin_link`, and that is the only file in this branch that is not path-library work.
The new test hands its child a curated `PATH`, and on a Windows userland a symlinked MSYS binary in a fakebin cannot load `msys-2.0.dll`, so the helper writes an exec-by-absolute-path shim there instead of a symlink.
Its POSIX branch is the `ln -s` loop that the call sites in this repo already open-code.

The same hunk appears in PR-6 and in the guard work that is not in this set, byte for byte, so no reviewer ever sees two versions of one function.
Merging this branch and PR-6 together does conflict once in `tests/lib.sh`, and the reason is worth stating exactly: PR-6's other helper is inserted immediately after this one, so the two additions share an anchor.
The conflict is add/add with an empty `ours` side, and the resolution is to take PR-6's file, which is a strict superset of this one's.
This branch also conflicts with PR-2 on one line of `bin/fm-test-run.sh`'s family map, where both add a test name; keep both.

## Notes for the reviewer

`bin/fm-brief.sh` changes by one sentence.
The isolation instruction told a crewmate to run `git rev-parse --show-toplevel` and `pwd -P` and check that they agree, which is exactly the comparison this branch shows is wrong.

`bin/fm-teardown.sh`'s `inspectable_git_worktree` is left alone on purpose.
It tests `[ -d "$top" ]` and nothing else, and `[ -d C:/... ]` is true under Git Bash, so it is not a defect.
