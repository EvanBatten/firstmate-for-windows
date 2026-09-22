# Firstmate verification map

This directory is the maintained source for verifying what firstmate does for the captain.
Read this index before driving anything, then use the matching feature file as the recipe.

## Baseline preconditions

- Stand in the worktree that holds the code under test.
- Run `.agents/skills/verify-firstmate/verify.sh doctor` and require `# doctor: worth driving`.
- Every drive uses a throwaway home the script builds for itself; no feature here needs, reads, or changes an operating home.
- No seed data is shared: each script files its own notes, work items, project repository, or second mate home.
- Never drive a home, a Herdr session, or a process that this verification run did not create.

## Driving conventions

- Drive a feature with `.agents/skills/verify-firstmate/verify.sh run <feature>`, where `<feature>` is the file name below without `.md`.
- Treat every command as literal, and keep quoted text and flags unchanged.
- One feature per script and one home per script, so order never matters and a failure in one says nothing about another.
- The scripts call `bin/` by absolute path from the worktree under test, exactly as the agent does.
- Exit `0` means every claim held, `77` means this machine cannot answer, and anything else is a real failure.

## Proof and skip reporting

- Each `ok -` line is one claim in plain language; quote the claims that matter, not only the summary.
- Proof of a change includes a baseline run on the base commit and a treatment run on the change, each with its own evidence directory.
- Proof of a record includes reading that record after the command, not only the command's output.
- Record the feature name, the entry point driven, and the evidence path with every result.
- Report an entry point you could not reach with the command you tried and the precondition that was missing.
- Do not report an entry point as verified because a different entry point passed.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing what the captain gets.
It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every entry point the captain or the agent has.
3. `Driving it with verify.sh` starts with `Preconditions:` and pairs each user action with the command that performs it and the observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map.
Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Captain inbox](./captain-inbox.md) covers a note dropped while firstmate is busy: queued, listed, delivered once, acknowledged, and no longer counted as waiting.
- [Notification queue](./wake-queue.md) covers durable delivery: presented, held until acknowledged, bound to the recovery episode that handed it out, and leaving nothing behind.
- [Captain decision](./captain-decision.md) covers a question that waits on the captain: carried by a real work item and closed only by his recorded words.
- [Local-only landing](./local-only-landing.md) covers approved local work: landed by fast-forward, and refused when the branch has diverged.
- [Real session](./real-session.md) covers the whole loop with a real worker: spawn into a visible tab, isolated work, a checked result, landing, and cleanup; it is opt-in because it spends tokens.
- [Condition watch](./condition-watch.md) covers "do X as soon as Y is true": armed, held until the condition holds, fired, reported, and retired.
- [Steer guard](./steer-guard.md) covers the two refusals that keep an instruction out of the wrong home.
- [Herdr lab pane](./herdr-lab-pane.md) covers the shell a worker pane runs: a pane made the production way runs what firstmate types, and a plain pane does not.
- [One home, two spellings](./lock-home-spelling.md) covers a home reached by two spellings of its path: every record lock under `state/` treats them as one home, completes, releases, and never grows a takeover chain.
- [Vanished endpoint recovery](./vanished-endpoint-recovery.md) covers getting a worker back after its window disappeared, without losing its work.
- [Second mate home](./secondmate-home.md) covers provisioning: identity, owner, charter, routing entry, and working skills.

Every verification script has a feature file here and every feature file has a script.
The doctor checks that, so a script added without its feature file makes the checkout not worth driving until the map is whole again.
