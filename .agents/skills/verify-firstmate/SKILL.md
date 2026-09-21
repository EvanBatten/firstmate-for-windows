---
name: verify-firstmate
description: >-
  Prove that a firstmate feature works by driving the real bin/ scripts against a throwaway home and keeping the evidence.
  Use before reporting a change to firstmate's own scripts as done, when checking that an installation or a platform works, and when something feels wrong and you need to know which feature is at fault.
  Firstmate's surface is its command-line scripts and the durable records they keep, so this skill drives scripts and reads records; it does not drive a browser.
user-invocable: true
metadata:
  internal: true
---

# verify-firstmate

The captain talks to an agent, and everything that agent does mechanically is a `bin/fm-*.sh` script acting on one operational home: the `data/`, `state/`, `config/`, and `projects/` directories that `FM_HOME` selects.
That pair, a script and the records it leaves in a home, is the surface this skill drives.
A test in `tests/` pins a contract with fakes and must pass on any machine.
This skill answers the other question: does the feature work for real, on this machine, with this code.

Two files own the detail, and this skill points at them instead of repeating them.
[`tests/verification/README.md`](../../../tests/verification/README.md) owns the contract every verification script keeps, the coverage table, and the name of any script that is red on purpose.
[`features/README.md`](features/README.md) is the feature map: what each feature is from the captain's side, how to drive it, and what end state proves it.
Read the feature file before you drive its feature.

Two surfaces are not driven here.
A worker pane in a runtime backend is touched by one feature only, `herdr-lab-pane`, and only through the guarded lab helper described under Cleanup.
A whole session with a real model worker spends tokens and needs the captain's word, so no script here starts one.

## Launch

There is nothing to build and no server to start.
Every verification script builds its own throwaway home under the system temp directory, points `FM_HOME` at it, and removes it when the script exits.
So launching means standing in the worktree that holds the code you want to prove and running the helper from there:

```sh
.agents/skills/verify-firstmate/verify.sh doctor
```

The helper resolves everything from the worktree that holds the helper file, never from your working directory, so the code it drives is the code beside it.
The instance is ready when the doctor prints `# doctor: worth driving`.

Nothing is shared between two worktrees, so parallel runs are the normal case.
The home comes from `mktemp` per script, the evidence directory is derived from the worktree path and the run, and the one feature that needs a Herdr session names its own with a process and random suffix.
The suite also clears every `FM_*_OVERRIDE` variable before it drives anything, because the directory ones win over `FM_HOME` inside the scripts and one left set by the caller would send the run into a live home.

## Doctor

```sh
.agents/skills/verify-firstmate/verify.sh doctor
```

The doctor writes nothing and exits `0` when the checkout is worth driving and `1` when it is not.
Run it first, and run it again whenever a result looks wrong.
It reports whether the suite is present, whether this is a linked worktree or the primary checkout, which commit is under test and how many paths are uncommitted, whether the harness skill link resolves, which tools are missing, and whether the temp directory can hold a throwaway home.
A `warn -` line does not stop a run, but read it: a missing optional tool means a feature will skip, and a skip proves nothing.
`run` calls the doctor itself and refuses to drive a checkout the doctor rejects.

## Drive

```sh
.agents/skills/verify-firstmate/verify.sh list                 # the features that can be driven
.agents/skills/verify-firstmate/verify.sh run wake-queue       # one feature
.agents/skills/verify-firstmate/verify.sh run                  # all of them
```

Every line a script prints is a claim about its feature in plain language, `ok - <claim>` or `not ok - <what is wrong>`.
The run ends with `verification: <n> passed, <n> failed, <n> skipped` and exits with the number of failed scripts.
A skipped script is one this machine could not answer, so report it as skipped and never as verified.

To prove a change, run the feature twice: once on the base your branch started from, in a worktree of that commit, and once on your change.
A script that is red on both sides is not your defect; check the suite README for a script that is red on purpose before you chase it.
A script that is green on both sides did not exercise your change, so it proves nothing about it.
Extend that script, or add one, until it fails without your change and passes with it.

When a feature has no script, add one to the suite the way its README describes instead of driving by hand, so the next agent inherits the proof.
If you must drive by hand, keep the same rules: a home you created with `mktemp`, holding `data/`, `state/`, `config/`, `projects/`, and a copy of `.tasks.toml`; `FM_HOME` exported to it; scripts called by absolute path from this worktree's `bin/`.
Never point a drive at a home you did not create.

## Evidence

Every run keeps its evidence here, and prints the path on its last line:

```
${TMPDIR:-/tmp}/fm-verification-artifacts/<worktree name>-<path checksum>/<UTC time>-<commit>-<pid>/
  doctor.txt                  what the doctor said before the run
  code.txt                    branch, commit, and every uncommitted path and diff under test
  run.log                     everything the run printed
  <feature>/transcript.txt    each claim the script checked, and the commit it ran against
  <feature>/<kept file>       any record the script chose to keep
```

`VERIFY_EVIDENCE_ROOT` moves the root.
The directory sits outside every worktree, so it survives the cleanup of the worktree that produced it.

A proof meets these standards.

- It exercises the path a user takes: the `bin/` script the captain or the agent really runs, with the arguments they really pass, not a library function, a test override, or a record written by hand.
- It captures the action and the resulting state, not only a final exit code.
- It reads the side effect from the durable record, such as a file under `state/` or `data/`, a backlog item, or a git ref, as well as from what the command printed.
- It fakes only a boundary the product already isolates, such as a project repository or a worker endpoint, and says so.
- It reports the evidence path and the summary line, and names every skip as a skip.

## Cleanup

Each script removes its own throwaway home from an exit trap, and `herdr-lab-pane` tears down its own lab session through `bin/fm-herdr-lab.sh teardown`.
Cleanup never touches the evidence directory.

A run that was killed can leave two things behind.
An `fm-verify-<feature>.*` directory under the temp directory is inert scratch; remove it only when you know the run that made it is yours and is over.
A Herdr session named `fm-lab-paneshell*` is removed with `bin/fm-herdr-lab.sh teardown <session>`, which refuses the default session.
`condition-watch` starts a background watch that carries its own three-minute deadline, so an interrupted run of it ends by itself.
Never stop a process by name, and never aim a `herdr` command at a session you did not create.

## Helpers

[`verify.sh`](verify.sh) is the only helper, and the three invocations above are all of it.
Run it with no arguments to print its own usage.

## Keeping the map honest

When a change alters how a feature is reached or which record proves it, update that feature's file under `features/` in the same change.
When a change adds a verification script, add its feature file and its line in the feature index.
