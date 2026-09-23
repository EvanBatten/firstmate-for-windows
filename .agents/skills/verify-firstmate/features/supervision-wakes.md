# Supervision wakes

The README promises low-token supervision: a bash watcher wakes the first mate only when something needs it.
This session proves that loop for real.
The captain asks for one change and to be left alone; the primary dispatches a worker and ends its turn, the Stop hook arms a watcher that spends no tokens, the worker's done line becomes a notification, the notification wakes the primary, and the primary lands the work and acknowledges the queue.
Every claim is read from the home's records and the observer's ticks.

## Sub-features

- `wakes-yield` sees the primary end its turn while a worker is in flight.
- `wakes-arm` sees a live watcher with a fresh beacon holding the home while the primary is idle, and no turn-end guard block in the fresh home.
- `wakes-signal` sees the worker's done line become a signal notification in the queue.
- `wakes-resume` sees the idle primary working again after the done line.
- `wakes-land` sees the change on main, correct when run, and the worker cleaned up with the queue acknowledged.

## How to get to it (user POV)

- The captain asks for a change and says to be woken when it is done.
- The primary dispatches through `bin/fm-spawn.sh` and ends its turn; `bin/fm-claude-stop-autoarm.sh` arms `bin/fm-watch.sh` through `bin/fm-watch-arm.sh`.
- The watcher queues a `signal` notification for the done line and wakes the primary through the Stop hook; the primary drains with `bin/fm-wake-drain.sh`, lands with `bin/fm-merge-local.sh`, cleans up with `bin/fm-teardown.sh`, and acknowledges the queue.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- The same preconditions as [Ship three changes in parallel](./ship-three-parallel.md).

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run supervision-wakes`.
- **Ask.** The script types one message: add the project, ship one change with the opus model, end the turn once the worker is dispatched, land it when done.
- **Dispatch.** One `state/<id>.meta` record appears.
- **Yield.** A tick in `ticks.tsv` shows a task record and the primary `idle` or `done`.
- **Arm.** `state/.watch.lock/pid` names a live process and `state/.last-watcher-beat` is under 300 s old; `state/.turnend-claude-blocks` does not exist.
- **Done and wake.** The status record gains `done:`; a later tick shows the primary `working` again, and a `records/` snapshot shows a `signal` line naming the task in `.wake-queue`.
- **Fresh throughout.** The beacon claim fails after three consecutive ticks that show an idle primary, work in flight, and a stale or missing beacon.
- **Land.** `projects/greeter` has `main` one commit ahead and `greet.sh` prints `hello from the crew` from a fresh clone.
- **Clean up and health.** No task record, no tab, and the health check every session gets, including an empty acknowledged queue.
- **Proof.** Read `supervision-wakes/transcript.txt`, `ticks.tsv`, `state-armed.txt`, the `records/` snapshots and the `panes/` snapshots.

## Gotchas

- Without the captain's "end your turn" sentence the primary tends to poll its worker inside one long turn, which this session then reports as a failed yield; three `ship-three-parallel` runs showed that shape.
- A `turnend-claude-blocks` record means the guard refused the first turn end in a fresh home, the race #86 describes.
- The wake is read from ticks ten seconds apart, so a primary that wakes and finishes within one tick would be missed; the landing claim still holds, and the transcript says which tick was missing.
