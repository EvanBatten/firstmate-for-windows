# Vanished endpoint recovery

A worker's window can disappear: someone closed it, or its session died.
The worker's isolated copy and its commits are still there, and the captain wants the worker back.
Firstmate must offer a way forward, and nothing on that path may cost the work that was already done.

## Sub-features

- `recovery-recognised` reads the vanished endpoint as gone.
- `recovery-route` lets a relaunch reach the launch step instead of refusing because there is nothing to stop.
- `recovery-exit-refuses` still refuses to stop a worker that is not there.
- `recovery-keeps-copy` keeps the isolated copy.
- `recovery-keeps-commit` keeps the commit that had not landed.
- `recovery-keeps-record` keeps the task's record.

## How to get to it (user POV)

- The captain says a worker's window is gone and asks for it back, and firstmate reads the task with `bin/fm-crew-state.sh <task-id>`.
- Firstmate relaunches it with `bin/fm-control.sh <task-id> relaunch --note <text>`.
- Firstmate stops a worker with `bin/fm-control.sh <task-id> exit`, which has nothing to stop here.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- No real agent is launched: the script shadows the harness with a stub that refuses to run, so a recovery that gets moving fails at the launch for an obviously different reason.
- Herdr must classify the fixture's missing pane as `pane_not_found`.
  Without that, the endpoint reads `unreadable` and relaunch refuses before the launch.
  That refusal is not the deadlock below.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run vanished-endpoint-recovery`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Read the state.** The script runs `bin/fm-crew-state.sh <task>` on a task whose recorded endpoint does not exist.
  The endpoint reads as gone.
- **Relaunch.** The script runs `bin/fm-control.sh <task> relaunch --note "the window was closed; pick the work back up"`.
  It reaches the launch step.
- **Stop.** The script runs `bin/fm-control.sh <task> exit`.
  It refuses, which is correct.
- **Check nothing was lost.** The isolated copy, its unlanded commit, and the task's record are all still there.
- **Proof.** Read `vanished-endpoint-recovery/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- This script was written while the defect was open and failed until its fix landed, so a failure here means the deadlock is back: relaunch refusing because there is nothing to stop, and stop refusing because there is nothing there.
- Reaching the launch step is the claim, not a running worker.
  A worker really coming back is proved only by [Real session](./real-session.md), and only for a first launch.
