# Steer a worker, refuse an early cleanup, land on the captain's word

Three things the captain relies on mid-task, run as one real session.
While a worker builds a change the captain adds a requirement; it reaches the worker as a durable record in its steering inbox, the worker acknowledges it, and the change shows in the worker's commit.
When the worker is done the captain asks for cleanup before landing; cleanup refuses to discard work that has not landed and the task, its copy and its commit stay put.
Then the captain lands it, and cleanup follows the landing.

## Sub-features

- `steer-record` writes the captain's words as a durable record under the task's inbox.
- `steer-ack` sees the worker acknowledge the record by moving it to `handled/`.
- `steer-effect` sees the steered requirement in the worker's commit.
- `refuse-unlanded` sees the task record, the isolated copy, its commit and the project's `main` untouched after a cleanup request on unlanded work.
- `land-on-word` sees the change land on `main` only on the captain's explicit word, correct when run, and the worker cleaned up afterwards.

## How to get to it (user POV)

- The captain tells firstmate something for the worker mid-task; firstmate sends it through `bin/fm-send.sh`, which records it under `state/<id>.inbox/` and rings the worker's terminal.
- The captain asks for cleanup before landing; `bin/fm-teardown.sh` refuses unlanded work and firstmate reports that.
- The captain lands the work; firstmate uses `bin/fm-merge-local.sh` and then `bin/fm-teardown.sh`.

## Driving it with verify.sh

Preconditions:

- The same preconditions as [Supervision wakes](./supervision-wakes.md).

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run steer-worker`.
- **Ask.** One change with three subcommands and a README section, the opus worker, end the turn after dispatch, and wait for the captain before landing.
- **Steer.** As soon as `state/<id>.meta` exists the script asks for a fourth subcommand, `shout`.
  A `state/<id>.inbox/NNN.msg` record appears carrying that word, and later sits under `handled/`.
- **Effect.** The worker's `done:` line appears and `greet.sh` at the worktree's tip mentions `shout`.
- **Refuse.** After the primary reports and waits, the script asks for cleanup before landing.
  Once the primary has answered, `state/<id>.meta` exists, the worktree and its commit exist, and `projects/greeter`'s `main` is unchanged.
- **Land.** The script gives approval; `main` advances, `greet.sh shout` prints `HELLO FROM THE CREW` from a fresh clone, and the task record and tab are gone.
- **Health.** The health check every session gets.
- **Proof.** Read `steer-worker/transcript.txt`, the kept inbox record, the status record, `project-log.txt`, and the `panes/` and `records/` snapshots.

## Gotchas

- The steer must reach the worker before it commits; the task is sized for a few minutes of work and the script sends the steer within seconds of dispatch.
  A worker that commits first and amends is still a pass, because the claim reads the tip.
- A primary that answers the cleanup request with a question is not a failure; the claim is that nothing was discarded.
  The script dismisses the question before the next message, as a captain would.
