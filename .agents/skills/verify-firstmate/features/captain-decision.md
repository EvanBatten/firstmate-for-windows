# Captain decision

When a question belongs to the captain, firstmate does not keep it in conversation memory.
The question rides on a real work item that reads as waiting on him, and only his own recorded words release and close it.

## Sub-features

- `decision-file` files an ordinary work item.
- `decision-hold` holds that item for the captain, with the question recorded on it.
- `decision-foreign` refuses a completion claim that names an origin this home does not own.
- `decision-answer` records the captain's exact words from a file.
- `decision-close` releases the hold and closes the item in the same act.

## How to get to it (user POV)

- The captain is asked a question in chat, and answers it in chat; firstmate records that answer with `bin/fm-captain-hold.sh answer <task-id> --decision-file <path>`.
- Firstmate holds a work item with `bin/fm-captain-hold.sh hold <task-id> --reason <question>`.
- The captain answers from a structured review surface, which feeds `bin/fm-captain-hold.sh answers` with keyed answers on standard input.
- Anyone reads what is waiting with `tasks-axi show <task-id>`.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving` and does not warn that `tasks-axi` is missing; without it this feature skips.
- The throwaway home carries a copy of `.tasks.toml`, which the script's home builder provides.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run captain-decision`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **File the work.** The script runs `tasks-axi add ship-or-wait --title "ship the notes or wait"` inside the home.
  It succeeds.
- **Hold it.** The script runs `bin/fm-captain-hold.sh hold ship-or-wait --reason "Ship now or wait for the fix? Options: ship now, wait."`.
  `tasks-axi show ship-or-wait` then prints `held: yes` and carries the text `Ship now or wait`.
- **Claim a foreign completion.** The script runs `bin/fm-captain-hold.sh complete not-our-origin ship-or-wait`.
  It is refused.
- **Record the answer.** The script writes `Ship now.` to a file and runs `bin/fm-captain-hold.sh answer ship-or-wait --decision-file <path>`.
  It succeeds.
- **Confirm the close.** `tasks-axi show ship-or-wait` prints `held: no` and `state: done`.
- **Proof.** Read `captain-decision/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- A skip here means `tasks-axi` is not installed.
  Report it as skipped; the feature is unproved on that machine.
- The keyed-answer entry point, `answers` on standard input, is not driven by this script, and neither is `--release`, which resumes held work instead of closing it.
- The claims read `tasks-axi show` output by its `held:` and `state:` lines, so a change to that tool's output format fails this script without any defect in firstmate.
  Check the tool's version before chasing the script.
- The script changes directory into the throwaway home because `tasks-axi` resolves its backlog from the working directory.
