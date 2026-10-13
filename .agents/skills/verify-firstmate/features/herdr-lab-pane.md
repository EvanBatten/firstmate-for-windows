# Herdr lab pane

Everything firstmate types into a worker's pane is POSIX shell.
On Windows a fresh Herdr pane opens a Windows shell, so the Windows overlay's Herdr layer, `platform/windows/herdr.sh`, makes every task pane run Git Bash on `platform/windows/pane-rc.sh` instead.
This feature proves that a pane created the way firstmate creates one runs what firstmate types, and that a pane created any other way does not.

## Sub-features

- `pane-lab` brings up an isolated lab session that is not the one the captain is using.
- `pane-plain` creates a plain workspace pane.
- `pane-task` creates a task pane through the production path.
- `pane-runs` sees the task pane run a POSIX command typed into it.
- `pane-differs` sees the plain pane not run it, which is the difference the production path exists for.

## How to get to it (user POV)

- The captain never creates a pane by hand; every worker tab comes from `bin/fm-spawn.sh`, which creates it through `fm_backend_herdr_create_task` in `bin/backends/herdr.sh`, with the overlay's Git Bash program on Windows.
- A test fixture or a developer reaches an isolated session with `bin/fm-herdr-lab.sh name <label>`, `bin/fm-herdr-lab.sh prepare <session>`, and `bin/fm-herdr-lab.sh teardown <session>`.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving` and does not warn that `herdr`, `jq`, or `timeout` is missing; without them this feature skips.
- On `main` this feature cannot pass yet, see Gotchas.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run herdr-lab-pane`.
  The suite prints `verification: 1 passed, 0 failed, 0 skipped`, then the inventory verdict and the evidence path, and takes a few minutes.
- **Lab session.** The script runs `bin/fm-herdr-lab.sh name paneshell` and `bin/fm-herdr-lab.sh prepare <session>`, then starts that session's server.
- **Two panes.** The script creates one pane with a plain `workspace create` and one through the backend's task-pane function, and waits for each pane's shell to settle.
- **Type into both.** The script types the same POSIX one-liner into each pane.
  The task pane runs it and the plain pane does not.
- **Teardown.** The script runs `bin/fm-herdr-lab.sh teardown <session>` from its exit trap.
- **Proof.** Read `herdr-lab-pane/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- Every Herdr call in the script is bounded, because an unbounded one once hung for hours.
  A timeout is reported as a failure that names the budget, not as a skip.
- The lab session is started by this run, so its panes inherit this shell's environment.
  It therefore cannot show a tool missing from a pane of the live session; [Real session](./real-session.md) is the feature that can.
- The script creates its task pane with `fm_backend_herdr_task_tab_create`, a function from the frozen `windows` branch that `main` does not have, and hides the error, so every run on `main` fails with `a task pane could not be created within 45s`.
  That failure is the script, not the product; until the script calls `fm_backend_herdr_create_task` with the overlay loaded, this feature has no live proof.
- The lab helper refuses the session named `default`.
  Never aim a `herdr` command at a session the run did not create.
