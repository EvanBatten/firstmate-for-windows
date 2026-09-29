# Real session

This is the whole loop the captain relies on, run for real.
He asks for a change, a worker appears in a new Herdr tab he can watch, the worker builds the change in its own isolated copy of the project, the result lands on the project's main, and nothing is left behind.
It is the only feature here that starts a real model worker.

## Sub-features

- `session-intake` files a work item and writes the worker's instructions.
- `session-spawn` starts a worker, in its own isolated copy of the project, in a new tab labelled `fm-<task>`.
- `session-trust` gets the worker past its folder-trust prompt.
- `session-work` sees the worker report its task done.
- `session-check` runs the worker's result instead of believing the report, and confirms the project's own checkout was never touched.
- `session-land` lands the approved work on main by fast-forward.
- `session-cleanup` removes the tab, returns the isolated copy, leaves no task records, and closes the work item.

## How to get to it (user POV)

- The captain asks firstmate for a change to a registered project.
- Firstmate files the work with `tasks-axi add`, writes instructions with `bin/fm-brief.sh <task> <project> --mode <mode>`, and starts the worker with `bin/fm-spawn.sh <task> <project-dir> --mode <mode> --yolo <on|off>`.
- The captain watches, or types into, the worker's tab in Herdr.
- Firstmate lands a finished local-only task with `bin/fm-merge-local.sh <task>` and cleans up with `bin/fm-teardown.sh <task>`.
- A project that ships through pull requests reaches the same spawn and cleanup with `bin/fm-pr-check.sh` and `bin/fm-pr-merge.sh` in between; this feature does not drive that path.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- You are inside a Herdr session, because the worker's tab opens in the workspace you are in.
- `herdr`, `jq`, `treehouse`, `claude`, `tasks-axi`, and `timeout` are installed, and `claude` is signed in.
- You accept that it spends model tokens and opens a tab the captain will see.
  Without `VERIFY_REAL_SESSION=1` the script skips and says so.

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run real-session`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`, and takes several minutes.
- **File and instruct.** The script builds a project with its own local `origin`, files a work item, and fills the instructions with a small task: add `greet.sh`.
- **Spawn.** The script runs `bin/fm-spawn.sh <task> <project> --mode local-only --yolo off --harness claude`.
  It succeeds, the recorded isolated copy is a linked worktree that is not the project's own checkout, and `herdr tab list` shows a tab labelled `fm-<task>`.
- **Trust prompt.** The script reads the pane, sends `Down` only when the cursor sits on "No", then sends `Enter`, both through `bin/fm-send.sh <task> --key <key>`.
- **Work.** The script waits for a `done:` line in the task's status record, keeping a snapshot of the pane every thirty seconds.
- **Check.** The script runs `bash greet.sh` and `bash greet.sh captain` in the isolated copy.
  They print `hello from the crew` and `hello captain from the crew`, and the project's own checkout is clean and unmoved.
- **Land.** The script runs `bin/fm-merge-local.sh <task>`.
  The project's main is at the worker's commit, one commit ahead of where it started.
- **Clean up.** The script runs `bin/fm-teardown.sh <task>`.
  The tab is gone, no `<task>.*` record is left under `state/`, and `tasks-axi show <task>` prints `state: done`.
- **Proof.** Read `real-session/transcript.txt` and the `pane-*.txt` snapshots in the evidence directory.
  The snapshots are the record of the worker at work; `spawn.err`, `merge.txt`, and `teardown.txt` hold what each step printed.

## Gotchas

- A smaller worker model can refuse the launch instructions as a prompt injection and never report anything.
  The script then fails at "the worker never reported done" and quotes the pane.
  Leave `VERIFY_REAL_SESSION_MODEL` unset unless that refusal is what you are testing.
- The trust prompt's default option has changed between harness versions, so never assume a bare `Enter` accepts it.
- A spawn that fails leaves its tab open; the script closes the tab it created, and only that one.
- The project needs an `origin`, even a local one, or the spawn refuses to start from a base it cannot refresh.
- This proves the local-only path with the claude harness on Herdr.
  The pull-request paths, scouts, steering a worker mid-task, other harnesses, and other backends are not driven here.
- The isolated copies live in a pool under `~/.treehouse/demo-<hash>`; cleanup returns the copy to its pool and does not delete the pool.
