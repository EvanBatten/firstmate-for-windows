# Local-only landing

Some projects never open a pull request: the worker stops with a finished local branch, and the captain approves landing it.
Firstmate lands that branch on the project's own main by fast-forward and by nothing else, because any other merge would rewrite history in a repository firstmate does not own.

## Sub-features

- `landing-ff` lands an approved branch and leaves main at the delivered commit.
- `landing-linear` adds no merge commit.
- `landing-refuse` refuses a branch that has diverged from main.
- `landing-untouched` leaves main exactly where it was after a refusal.

## How to get to it (user POV)

- The captain says to land a finished local-only task, and firstmate runs `bin/fm-merge-local.sh <task-id>`.
- A project whose standing posture lets firstmate merge green work by itself reaches the same command without a separate approval.
- There is no other entry point: no other script lands local work.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- The script builds its own project repository under the throwaway home's `projects/`, a work branch `fm/demo` in a separate worktree, and the task's durable record naming both; nothing outside the throwaway home is a project here.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run local-only-landing`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Land approved work.** The script runs `bin/fm-merge-local.sh demo`.
  It succeeds.
- **Read main.** The script runs `git rev-parse main` in the project.
  It equals the branch's delivered commit, and `git rev-list --count <base>..main` prints `1`, so nothing but the delivered commit was added.
- **Diverge, then land again.** The script commits once on main and once on the branch, then runs `bin/fm-merge-local.sh demo`.
  It is refused.
- **Read main again.** `git rev-parse main` still prints the commit from before the refused landing.
- **Proof.** Read `local-only-landing/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- The proof is the project's git refs, not the command's exit code.
  A landing that reports success and leaves main behind is exactly the failure this covers.
- On Windows, git prints line-ending warnings for the fixture files into the run log.
  They are noise from the fixture, not a finding.
- The script writes the task's durable record by hand instead of dispatching a worker, because the worker boundary is one the product already isolates.
  It therefore proves the landing, not the dispatch that would normally write that record.
- The approval itself is a conversation with the captain and is not driven here; the script starts from "approved".
