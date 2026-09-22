# One home, two spellings

On Git Bash the system temp directory is mounted at `/tmp`, so a home under it has two spellings, `/tmp/x` and `/c/Users/<you>/AppData/Local/Temp/x`, and a harness hands firstmate the second.
Every record lock under `state/` must treat those as one home: the command completes, the lock is released, and no takeover chain grows.
Before the fix for #82 the lock compared the two spellings as text, took its own lock for a stranger's, and stole from itself without bound until supervision stalled.

## Sub-features

- `spelling-note` queues a captain note under either spelling.
- `spelling-chain` grows no `.steal` takeover chain under either spelling.
- `spelling-release` leaves no queue lock behind under either spelling.
- `spelling-drain` presents the queued note under either spelling.

## How to get to it (user POV)

- Any firstmate started from a home whose path the harness spells differently from the shell: the session-start digest, every notification drain, every captain note, every spawn takes one of these locks.
- On Windows that is every home under the system temp directory, and the runaway chain was first seen in a real session there.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- On a machine whose temp directory has one spelling, both drives use the same path and must still pass.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run lock-home-spelling`.
- **Two spellings.** The transcript names the home under both spellings, or says the temp directory has one.
- **Note and drain, twice.** For each spelling the script runs `bin/fm-inbox.sh note` and then `bin/fm-wake-drain.sh` against the same home.
  Each completes within 60 s, `state/` holds no `*.steal*` entry and no `.wake-queue.lock*` entry afterwards, `.wake-queue` holds exactly one row, and the drain output names the captain inbox note.
- **Proof.** Read `lock-home-spelling/transcript.txt`; on a failure `state-<spelling>.txt` lists the chain that grew.

## Gotchas

- The failing spelling is the physical one, `/c/...`, because `readlink` reports a link target under the mount alias while `mktemp` keeps the spelling it was given.
  A drive that only uses `/tmp` paths proves nothing about #82.
- A hang here is the defect, not a slow machine: the 60 s budget is ten times what one note needs.
