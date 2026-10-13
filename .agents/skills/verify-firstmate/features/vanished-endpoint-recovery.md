# Vanished endpoint recovery

A worker's window can disappear: someone closed it, or its session died.
The worker's isolated copy and its commits are still there, and the captain wants the worker back.
Firstmate must offer a way forward, and nothing on that path may cost the work that was already done.

## Sub-features

- `recovery-recognised` reads the vanished endpoint as gone.
- `recovery-route` lets a relaunch reach the launch step instead of refusing because there is nothing to stop.
- `recovery-exit-gone` stops a worker that is not there by reporting its endpoint gone, without touching the work.
- `recovery-keeps-copy` keeps the isolated copy.
- `recovery-keeps-commit` keeps the commit that had not landed.
- `recovery-keeps-record` keeps the task's record.

## How to get to it (user POV)

- The captain says a worker's window is gone and asks for it back, and firstmate reads the task with `bin/fm-crew-state.sh <task-id>`.
- Firstmate relaunches it with `bin/fm-control.sh <task-id> relaunch --note <text>`.
- Firstmate stops a worker with `bin/fm-control.sh <task-id> exit`, which has nothing to stop here and says so.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- `herdr` and `jq` are installed; without them the script skips, because its task record names a Herdr lab session.
- No real agent is launched: the script shadows the harness with a stub that refuses to run, so a recovery that gets moving fails at the launch for an obviously different reason.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run vanished-endpoint-recovery`.
  The suite prints `verification: 1 passed, 0 failed, 0 skipped`, then the inventory verdict and the evidence path.
- **Read the state.** The script runs `bin/fm-crew-state.sh <task>` on a task whose recorded endpoint does not exist.
  The endpoint reads as gone.
- **Relaunch.** The script runs `bin/fm-control.sh <task> relaunch --note "the window was closed; pick the work back up"`.
  It reaches the launch step.
- **Stop.** The script runs `bin/fm-control.sh <task> exit`.
  It exits `0` and prints `endpoint-gone`.
- **Check nothing was lost.** The isolated copy, its unlanded commit, and the task's record are all still there.
- **Stop the lab session.** The script tears down its lab session, and `herdr session list` no longer names it.
- **Proof.** Read `vanished-endpoint-recovery/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- This script was written while the defect was open and failed until its fix landed, so a failure of the relaunch claim means the deadlock is back: relaunch refusing because there is nothing to stop.
- The task record names a lab session the script reserves with `bin/fm-herdr-lab.sh name gone` and `prepare`, because relaunch starts that session's server; the script tears it down and claims it is gone, so no run leaves a server behind or touches another run's session.
- Reaching the launch step is the claim, not a running worker.
  A worker really coming back is proved only by [Real session](./real-session.md), and only for a first launch.
