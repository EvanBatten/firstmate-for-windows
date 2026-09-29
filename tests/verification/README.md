# Verification suite

One script per feature, each answering a single question: does this feature work on **this** installation?

```sh
tests/verification/run.sh                 # all of them
tests/verification/run.sh secondmate-home # just one
```

## What these are, and what they are not

A script in `tests/` pins a contract with fakes and must pass on any machine.
A script here runs the real `bin/` scripts against a real throwaway home and reports what actually happened.
They exist because a green portable lane does not tell you the tool works on the machine in front of you: two of the defects they cover shipped green lanes and a clean worktree while the feature was silently broken.
A script passing here is evidence about one path through one feature, driven against a throwaway home with no real firstmate agent in it; it is not proof that the behavior works end to end, and this directory does not claim otherwise.
[`../../.agents/skills/verify-firstmate/behaviors.tsv`](../../.agents/skills/verify-firstmate/behaviors.tsv) is the one place that counts what is actually proven, and a script's own green run never promotes a row there by itself.

Run them by hand before trusting an installation, after a platform change, and when something feels wrong and you want to know which feature is at fault.

## The contract each script keeps

- **One feature.** The filename names it, and every line of output is a claim about that feature in plain language.
- **Its own home.** Each builds a throwaway home under the system temp directory and removes it on exit, so nothing touches an operating home and order never matters.
- **No shared state.** A failure in one says nothing about the others.
- **Honest exit.** `0` all passed, `77` this machine cannot answer the question, anything else is a real failure.
- **A failure says what is wrong, not which assertion tripped.** "the harness skill link is a plain file holding ../.agents/skills, so this mate has no skills" beats "expected symlink".

## Current coverage

| Script | Feature |
| --- | --- |
| `captain-inbox` | A note captured mid-turn reaches firstmate once, and stops counting as waiting after it is handled |
| `wake-queue` | Work is delivered, survives until acknowledged with the generation it was handed, and leaves nothing behind |
| `captain-decision` | A question for the captain is carried by a real work item until his own words close it |
| `condition-watch` | "Do X as soon as Y is true" fires its action and tells firstmate |
| `steer-guard` | An instruction is never delivered to a worker in the wrong home |
| `steer-worker` | A mid-task instruction reaches the worker as a durable inbox record it acknowledges and that shows in its commit, cleanup refuses unlanded work, and the change lands on the captain's word; a session, opt-in with `VERIFY_REAL_SESSION=1` |
| `supervision-wakes` | With a worker in flight the primary ends its turn, the watcher takes over with a fresh beacon, and the done line wakes the primary to land the work; a session, opt-in with `VERIFY_REAL_SESSION=1` |
| `local-only-landing` | Approved local work lands by fast-forward, and a diverged branch is refused |
| `secondmate-home` | A provisioned second mate home has its identity, charter, routing entry, and working skills |
| `herdr-lab-pane` | A pane firstmate is about to drive runs a shell firstmate can drive |
| `lock-home-spelling` | A home reached by two spellings of its path is one home to every record lock: the command completes, the lock is released, and no takeover chain grows (#82) |
| `vanished-endpoint-recovery` | A task whose endpoint disappeared can still be recovered, and its work survives either way |
| `real-session` | The whole loop with a real worker: a spawn opens a visible Herdr tab, the worker builds a task in its own isolated copy, the result is checked, lands, and is cleaned up. Opt-in with `VERIFY_REAL_SESSION=1`, because it spends tokens |
| `restart-primary` | With a worker in flight the primary exits and a new one starts in the same home, takes the lock under its own identity, lands the worker's change and cleans up; a session, opt-in with `VERIFY_REAL_SESSION=1` |
| `scout-report` | A scout answers the captain's question in data/<id>/report.md without touching the project, the same task is promoted to build the authorized change, and the report survives cleanup; a session, opt-in with `VERIFY_REAL_SESSION=1` |
| `ship-three-parallel` | A real firstmate primary in a fresh home takes one request for three changes, dispatches three workers into their own tabs and isolated copies, lands all three on main and cleans up, judged from records; a session, opt-in with `VERIFY_REAL_SESSION=1` |

Three of these carry a defect that already bit us. `wake-queue` covers the temp files a drain used to abandon (#59) and `secondmate-home` the skills a mate used to be silently provisioned without (#60), both now fixed. `vanished-endpoint-recovery` reproduces #58 and is the acceptance check for its fix: it fails on the code before the fix with the deadlock in its own words, and passes after.

## Evidence

Every run writes a transcript to `$TMPDIR/fm-verification-artifacts/<script>/`, naming the commit it ran against, so a result can be read an hour later instead of scrolling past. `VERIFY_ARTIFACT_DIR` moves that elsewhere. Scripts keep supporting files beside the transcript with `verify_keep`.
A second run of the same script overwrites that transcript, so an agent proving a change drives the suite through the [`verify-firstmate`](../../.agents/skills/verify-firstmate/SKILL.md) skill, which gives every worktree and every run its own evidence directory.

## A red script stays red

`vanished-endpoint-recovery` was written while #58 was still open, failed on `windows` with the tool's own refusal in its output, and went green when the fix landed.
That is the pattern to keep: a script that reproduces a known defect is the acceptance check for its fix.
Do not make a script skip to keep the summary tidy.
A suite that is quiet about a known defect is worth less than one that is noisy about it.

## Measuring coverage

```sh
tests/verification/coverage.sh                # every script, as long as the suite takes
tests/verification/coverage.sh real-session   # add one script to an earlier measurement
```

A claim that a feature is covered is only as good as the evidence that its code ran.
`coverage.sh` runs each script with a `BASH_ENV` hook that records every bash script the run starts, then writes `coverage.tsv` beside the other evidence: one row for every script under `bin/`, whether a verification script really ran it and which one, and how many suites under `tests/` name it.
A sourced library counts as run when a script that ran sources it.
The report measures; it does not judge.
[`coverage.tsv`](coverage.tsv) in this directory is the last committed measurement; regenerate it and commit it with the change that moved it.

## Adding one

Copy the shape of an existing script: source `lib.sh`, call `verify_home`, use `ok` and `bad`, end with `verify_done`.
Call `verify_skip` when the machine genuinely cannot answer, which is not a failure.
Do not reach for `verify_home` inside a command substitution; it sets globals, and a subshell would drop them.
