# Notification queue

Everything that needs firstmate's attention arrives through one durable queue.
Work in that queue is presented to firstmate and stays there until firstmate acknowledges it with the generation that drain printed.
An interrupted turn loses nothing, because a later look presents the same rows.
A stale generation does not mark the recovery episode acknowledged.
The owned rows are still removed, the command exits 0, and the drain says a newer episode is pending.

## Sub-features

- `queue-present` presents every queued item.
- `queue-ack-named` prints the exact acknowledgement the handling turn must run.
- `queue-survive` presents unacknowledged work again on the next look.
- `queue-generation` refuses to let a stale generation retire a recovery episode, and lets the episode's own generation retire it.
- `queue-ack` accepts the right acknowledgement and then presents nothing.
- `queue-clean` leaves no temporary file in the home after the queue empties.

## How to get to it (user POV)

- Firstmate runs `bin/fm-wake-drain.sh` at the start of every turn that a notification woke.
- Firstmate runs the printed `bin/fm-wake-drain.sh --ack-through <seq> --recovery-generation <generation>` after it has handled what was presented.
- The session-start digest presents the same queue once, in its notification section.
- Anything that needs attention puts work in: a worker's status line, a poll result, a captain note, a watched condition.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- The script fills the queue through the captain inbox, so [Captain inbox](./captain-inbox.md) must work on this machine for this result to mean anything.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run wake-queue`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Queue two items.** The script runs `bin/fm-inbox.sh note "first"` and `bin/fm-inbox.sh note "second"`, then `bin/fm-wake-drain.sh`.
  Two `check: captain inbox note` lines appear.
- **Read the acknowledgement.** The same output carries `WAKE_ACK_REQUIRED` with `--ack-through <seq>` and `--recovery-generation <generation>`.
- **Look again without acknowledging.** The script runs `bin/fm-wake-drain.sh` a second time.
  Both items are presented again.
- **Offer a stale generation.** With a recovery episode pending in the home, the script runs the acknowledgement with `--recovery-generation 99999.1.bogus`.
  The episode record under `state/` is not retired.
- **Offer the right generation.** The script runs the acknowledgement with the generation the drain printed.
  The episode record reads as acknowledged.
- **Acknowledge the work.** The script runs the original acknowledgement.
  It succeeds, and the next `bin/fm-wake-drain.sh` presents no inbox item.
- **Check the home.** The script lists `state/` for leftover `.wake-rows.consume.*` and `.main-eligible-rows.tmp.*` files.
  There are none.
- **Proof.** Read `wake-queue/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- With no recovery episode pending, any generation is accepted, because there is nothing to bind to.
  The script creates an episode on purpose; a hand drive that skips that step proves nothing about generations.
- The session-start entry point is not driven here.
  It presents the same queue, but its own digest is unproved by this script.
- The leftover-file claim is the regression check for a defect that leaked one empty file per acknowledgement, so do not weaken it to a count.
- Only the captain inbox feeds the queue in this script.
  Worker status lines and poll results use other producers that this script does not exercise.
