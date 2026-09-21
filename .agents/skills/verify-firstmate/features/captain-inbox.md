# Captain inbox

The captain can drop a note for firstmate while firstmate is busy and cannot answer.
The note is kept durably, reaches firstmate exactly once at its next look at the notification queue, and stops counting as waiting once firstmate has handled it.

## Sub-features

- `inbox-queue` keeps a note and reports the id it was given.
- `inbox-list` shows the note as waiting, in the list and in the read-only status.
- `inbox-deliver` presents the note to firstmate as one notification.
- `inbox-ack` lets firstmate acknowledge the note and its notification.
- `inbox-once` never delivers an acknowledged note again and no longer counts it as waiting.

## How to get to it (user POV)

- The captain runs `bin/fm-inbox.sh note <text>` in any terminal, or `bin/fm-inbox.sh note -` with the text on standard input.
- The captain speaks a request to the voice handover, which queues it through the same `note` command.
- The captain runs `bin/fm-inbox.sh status` or `bin/fm-inbox.sh list` to see what is waiting.
- Firstmate meets the note when it runs `bin/fm-wake-drain.sh`, and closes it with `bin/fm-inbox.sh drain --ack <id>`.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- No configuration is needed: `note`, `status`, `list`, and `drain` make no model call and no network call.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run captain-inbox`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Queue a note.** The script runs `bin/fm-inbox.sh note "the release notes need a look"`.
  The claim `ok - the note is queued and names its own id` holds when the command prints `queued <id>`.
- **See it waiting.** The script runs `bin/fm-inbox.sh list` and `bin/fm-inbox.sh status`.
  The list names the id and the status reports `1 note`.
- **Deliver it.** The script runs `bin/fm-wake-drain.sh`.
  The output names the id and prints a `WAKE_ACK_REQUIRED` line carrying `--ack-through` and `--recovery-generation` values.
- **Acknowledge it.** The script runs `bin/fm-inbox.sh drain --ack <id>` and then `bin/fm-wake-drain.sh --ack-through <seq> --recovery-generation <generation>` with the values the drain printed.
  Both succeed.
- **Confirm it is gone.** The script runs `bin/fm-wake-drain.sh` and `bin/fm-inbox.sh status` again.
  The id is not presented a second time and the status no longer reports `1 note`.
- **Proof.** Read `captain-inbox/transcript.txt` in the evidence directory.
  One `ok` line per claim above and no `FAIL` line prove the feature, and the header names the commit it ran against.

## Gotchas

- `say` and `ask` call a model and are off until the home configures them; this feature covers `note` only, and a passing run says nothing about speech or side questions.
- A note has two acknowledgements, one for the note and one for its notification.
  Skipping the first leaves the note counted as waiting even though firstmate saw it.
- The voice handover entry point is not driven here.
  It reaches the same `note` command, but the speech path in front of it is unproved by this script.
