# Steer guard

Firstmate steers a worker by sending it text.
An instruction delivered to a worker in the wrong home would land on somebody else's crew, so the send refuses when it is not told which home it means, and refuses a worker that home does not have.

## Sub-features

- `steer-no-home` refuses a steer when no home is named.
- `steer-names-cause` says what is missing in the refusal.
- `steer-unknown-worker` refuses a steer to a worker the home does not have.

## How to get to it (user POV)

- The captain tells firstmate to redirect or answer a worker, and firstmate runs `bin/fm-send.sh <task-id> <text>` with `FM_HOME` set to the home that owns the worker.
- Firstmate sends a key instead of text with `bin/fm-send.sh <task-id> --key <key>`.
- There is no other way to reach a worker's inbox.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run steer-guard`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Steer with no home.** The script runs `env -u FM_HOME bin/fm-send.sh some-task "hello"`.
  It is refused, and the refusal names `FM_HOME`.
- **Steer an unknown worker.** The script runs `bin/fm-send.sh no-such-task "hello"` with `FM_HOME` set to the throwaway home.
  It is refused.
- **Proof.** Read `steer-guard/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- This proves the two refusals only.
  An accepted text steer, its durable inbox record, and the worker's acknowledgement are not proved by any script yet; [Real session](./real-session.md) sends keys, not text.
- The first drive removes `FM_HOME` from the environment on purpose.
  Running the same command from a shell that exports `FM_HOME` proves nothing about the refusal.
