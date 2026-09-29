# Restart is a non-event

The README promises restart-proof operation: all state lives on disk and in the session backend, so a new session reconciles and carries on.
This session proves it for real.
With a worker in flight the captain's window closes and opens again; a new primary starts in the same home, takes the lock under its own identity, finds the worker from the durable records, lands its work when it is done, and cleans up, and the worker never notices.

## Sub-features

- `restart-survive` sees the worker's record and pane untouched by the primary's exit and relaunch.
- `restart-relock` sees the new session take `state/.lock` under a different identity than the old one.
- `restart-carry-on` sees the new session land the worker's change and clean up from the records alone.

## How to get to it (user POV)

- The captain closes the terminal, or the harness exits, while a worker is building.
- The captain opens a new terminal in the same home and launches the harness again; `bin/fm-session-start.sh` takes the lock and prints the digest with the task in flight.
- The captain says to carry on; the new primary supervises through the watcher, lands with `bin/fm-merge-local.sh` and cleans up with `bin/fm-teardown.sh`.

## Driving it with verify.sh

Preconditions:

- The same as [Supervision wakes](./supervision-wakes.md): inside Herdr, `claude` signed in, the toolchain beside the primary checkout, `VERIFY_REAL_SESSION=1`.

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run restart-primary`.
  It takes fifteen to twenty-five minutes.
- **Ask and dispatch.** One change with the opus worker and an instruction to end the turn after dispatch; a `state/<id>.meta` record appears and the primary goes idle.
- **Restart.** The script sends `/exit`, waits for the shell prompt, and starts `claude` again in the same pane.
  `state/<id>.meta` still exists and the worker's pane still answers.
- **Relock.** After the captain's "I'm back" message, `state/.lock` holds a different identity than before the restart.
- **Carry on.** `projects/greeter`'s `main` advances by the worker's commit, `greet.sh hello` prints a line from a fresh clone, the README documents the subcommands, and no task record or tab remains.
- **Health.** The health check every session gets.
- **Proof.** Read `restart-primary/transcript.txt`, `lock-after-restart.txt`, `project-log.txt`, `ticks.tsv`, and the `panes/` snapshots around `before-relaunch`.

## Gotchas

- The new session's trust prompt does not appear again for a folder already trusted, so the launch may go straight to the ready prompt.
- A restart while the worker is between its turns is the interesting case; the script restarts as soon as the first primary has yielded, which is early in the worker's build.
