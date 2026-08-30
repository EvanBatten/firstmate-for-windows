# PR-3: make the herdr adapter speak Windows paths and MSYS argument rules

Branch: `EvanBatten:pr-3-herdr-windows-cli` -> `kunchenguid/firstmate:main`.
One commit, 4 files, +556 -4, of which +410 is a new cross-platform test.
Independent of PR-1 and PR-2; PR-4 is stacked on this one.

## What is wrong today

herdr runs natively on Windows and the adapter cannot talk to it.
Three separate reasons, each of which alone refuses every spawn.

### 1. The socket identity check rejects the path herdr itself reports

`fm_backend_herdr_canonical_socket_path` requires a `/`-leading path.
On Windows herdr reports its socket in native spelling, on **both** sides of the same-session proof - the `HERDR_SOCKET_PATH` it injects into a pane and the `socket_path` in `session list --json`:

```console
$ herdr session list --json | jq -r '.sessions[]|select(.name=="default")|.socket_path'
C:\Users\ebatt\AppData\Roaming\herdr\herdr.sock
$ bash -c '. bin/backends/herdr.sh; fm_backend_herdr_presentation_session_socket_path default'
                                                    # refused, empty
```

So the adapter compares a path it refuses to canonicalize against another path it refuses to canonicalize, decides they are not the same session, and refuses the spawn.
(This is the same defect as issue #3283.)

### 2. MSYS rewrites arguments before the native `herdr.exe` sees them

MSYS converts `/`-leading arguments to Windows paths on the way into a native binary.
That is wanted for `--cwd` and catastrophic for everything else:

```console
$ herdr tab list --workspace /clear --session default
{"error":{"code":"workspace_not_found","message":"workspace C:/Program Files/Git/clear not found"}}
$ MSYS2_ARG_CONV_EXCL='*' herdr tab list --workspace /clear --session default
{"error":{"code":"workspace_not_found","message":"workspace /clear not found"}}
```

Any workspace, label, `--match` value or `send-text` payload that starts with `/` is silently mangled, including every slash command a crewmate is sent.

### 3. The presentation lock namespace can never be valid

`fm_backend_herdr_presentation_lock_namespace_valid` requires the namespace directory to read mode 700.
Every Git Bash mount is `noacl`, so POSIX modes are not representable: `mkdir -m 700` produces a 755 directory and exits 1.
The requirement is unsatisfiable, so the adapter refuses its own presentation lock and prints `herdr task kill could not acquire its session presentation lock; refusing an unlocked pane close` on every close.

## The fix

All three are keyed on a **capability**, never on `uname`.

**Socket identity.** `fm_backend_herdr_canonical_socket_path` accepts a `[A-Za-z]:[/\]`-shaped path and folds it through `cygpath -u`, and refuses it when there is no `cygpath`.
That refusal is what keeps a POSIX host byte-identical: a shell that cannot read that spelling is not looking at an absolute path, it is looking at a relative one with a colon in it, and it refuses exactly as it did before.
The comparison itself moved into `fm_backend_herdr_socket_paths_equal`, which folds case only where `cygpath` exists - the marker for a Windows userland, whose filesystem is case-insensitive and where `C:\Users` and `c:\users` are one socket.
The fold runs only after a byte comparison has already failed.

**Argument conversion.** `fm_backend_herdr_cli` routes through `fm_backend_herdr_cli_win32` when `fm_backend_herdr_win32_cli` says the `herdr` on `PATH` is a native Win32 binary.
That branch sets `MSYS2_ARG_CONV_EXCL='*'` for the whole call and converts `--cwd` itself with `cygpath -w` (both the `--cwd <path>` and `--cwd=<path>` spellings).
`MSYS_NO_PATHCONV` is deliberately not used: setting it to an *empty* value also disables conversion, which makes it a trap inside a wrapper.

**Lock namespace.** Owner identity is still required unconditionally.
The mode check is now conditional on the mode meaning anything: when the directory does not read 700, `fm_backend_herdr_presentation_lock_namespace_modeless` creates one `mktemp -d` probe and reads its mode back.
Only a filesystem that drops modes answers with anything but 700, so a genuinely group-readable namespace on a mode-capable filesystem still fails.

The probe is created **beside** the namespace, never inside it, and that placement is the security argument.
The probe only runs when the namespace is not 700 - exactly the state in which an attacker may have write access to it - so a probe placed inside at a predictable name (`$$` is readable from `/proc`) could be pre-created by that attacker as a mode-000 or symlinked directory, surviving both the `rm -rf` and the `mkdir`, and answering "this filesystem drops modes" on a Linux box where it does not.
`mktemp -d` in the parent removes both halves: the name is unpredictable and `/tmp`'s sticky bit stops anyone but the owner removing or renaming the entry.

Per the port plan this relaxation is confined to this one site.
The other 32 mode-700 sites in `bin/` are left alone; sweeping them is a separate decision that needs your input, not a rider on this patch.

### The probe that keeps every existing test honest

`fm_backend_herdr_win32_cli` asks whether `command -v herdr` resolves to a file whose first two bytes are `MZ`.
That is not a proxy for Windows - it is the exact condition under which MSYS converts arguments, because MSYS converts for native binaries and not for the MSYS shell scripts it runs itself.
Which means the fake `herdr` that every unit test in `tests/` puts on `PATH` keeps the plain branch, on Windows too, and goes on asserting the byte-exact argument lists it always did.
`FM_BACKEND_HERDR_WIN32_CLI=1/0` forces the answer so a test can drive the conversion branch with a shell-script fake.

## What did not change

On a POSIX host the new `fm_backend_herdr_cli` gate is two `command -v` builtins and no extra process.
`fm_backend_herdr_socket_paths_equal` reaches its case fold only where `cygpath` exists.
`bin/backends/herdr-workspace-move.py` keeps its existing behavior everywhere except that it now returns its existing "invalid transport" status 2 when `socket.AF_UNIX` is absent, instead of raising `AttributeError`.

## Verification

| Check | Result |
| --- | --- |
| `bin/fm-lint.sh` on all three touched shell files | clean, ShellCheck 0.11.0, full extended analysis |
| `python3 -m py_compile bin/backends/herdr-workspace-move.py` | clean |
| `tests/fm-backend-herdr-windows.test.sh` (new, 21 cases) | 21 / 21 on Windows, and on a POSIX host |
| `bin/fm-test-run.sh --check-coverage` | `ok total=168 parallel=24 serial=132 serial_shards=4 herdr=12` |
| `tests/fm-backend-herdr-smoke.test.sh`, real herdr 0.8.2, isolated lab session | zero presentation-lock warnings, where Phase A printed three |
| socket canonicalization, live | `/c/Users/ebatt/AppData/Roaming/herdr/herdr.sock` (was: refused) |
| presentation lock path, live | `/tmp/firstmate-herdr-presentation/order-<hash>.lock` (was: refused) |

The new test fakes `uname`, `cygpath`, a PE-magic `herdr` and a mode-less `stat`, so **all 21 cases run on Linux and macOS CI**.

## Notes for the reviewer

**One deliberate widening to flag.** The lock relaxation keys on the capability ("this filesystem cannot carry a mode"), not on the platform, so a Linux host whose `/tmp` sat on vfat or exfat would also take it.
On such a mount the 700 requirement is unsatisfiable rather than protective, so this is arguably right - but it is broader than "when the mount reports noacl", so it is named rather than buried.

**Two accepted limitations.** A `pane send-text` payload that is literally `--cwd=<path>` would be converted, because the scan is positional-blind; that is contrived and strictly better than the pre-change MSYS behavior.
A `herdr` installed as a `.bat`/`.cmd` shim would be native to MSYS without being a PE image, so it would take the plain branch and get its arguments mangled; the official installer ships an `.exe`.

**One defect in this area that this branch does not carry yet.** A native `jq.exe` opens stdout in text mode, so a multi-row `jq -r` read carries an interior CR: the workspace-ambiguity refusal rendered `w1\r w7`, which looks correct on a terminal and matches nothing, and `tests/fm-backend-herdr.test.sh` was red at that case on Windows.
The fix is one `fm_backend_herdr_jq_rows` funnel with every array-iterating read moved onto it - thirteen of the adapter's 61 `jq -r` reads, four of them previously masked by a `| head -1` rather than fixed by it - and on a POSIX host it runs the identical pipeline for identical bytes and status.
It is written and verified (that suite is 181/181 on Windows, plus eleven cross-platform cases, four of which drive a real call path - including that refusal - through a text-mode jq fake) and it arrives as a follow-up commit on this branch.
