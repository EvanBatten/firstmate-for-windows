# Scout, report, promote

The README promises two kinds of task: ship tasks deliver authorized changes and scout tasks leave standalone investigation reports.
This session proves the scout half and the road from a report to a change.
The captain asks a question; a scout answers it in `data/<id>/report.md` without touching the project; the captain then authorizes the change; the same task is promoted to a ship task, builds and lands the change, and cleanup keeps the report.

## Sub-features

- `scout-kind` sees the dispatched worker recorded as a scout.
- `scout-report` sees a report under `data/<id>/report.md` and the project unchanged.
- `scout-promote` sees the same task record flip to a ship task with ship instructions written, and no second task started.
- `scout-land` sees the promoted worker's change land on `main` and run from a fresh clone.
- `scout-keep-report` sees the report survive cleanup.

## How to get to it (user POV)

- The captain asks for an investigation or a written answer rather than a change.
- Firstmate dispatches a scout with `bin/fm-spawn.sh --scout`; the scout writes `data/<id>/report.md`; firstmate relays the findings.
- The captain authorizes the change; firstmate promotes the scout with `bin/fm-promote.sh` instead of starting a second worker, then lands and cleans up as for any ship task.

## Driving it with verify.sh

Preconditions:

- The same as [Supervision wakes](./supervision-wakes.md): inside Herdr, `claude` signed in, the toolchain beside the primary checkout, `VERIFY_REAL_SESSION=1`.

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run scout-report`.
  It takes twenty to thirty minutes.
- **Ask.** An investigation into which subcommands the greeter should have, as a written report, with the opus worker.
- **Scout.** `state/<id>.meta` says `kind=scout`.
- **Report.** `data/<id>/report.md` appears and mentions the greeter; the project's `main` and working tree are unchanged.
- **Promote.** After the captain's authorization the same record says `kind=ship` or `data/<id>/ship-instructions.md` exists, and there is still exactly one task record.
- **Land.** `main` advances and `greet.sh` runs from a fresh clone.
- **Keep.** No task record or tab remains, and the report is still there.
- **Health.** The health check every session gets.
- **Proof.** Read `scout-report/transcript.txt`, `report.md`, `ship-instructions.md`, `project-log.txt` and the `panes/` snapshots.

## Gotchas

- A primary that starts a second worker for the change instead of promoting the scout fails the promotion claim; that is the behavior under test, not a harness limit.
- The report claim needs the word greet in the report, so a report written about something else fails it.
