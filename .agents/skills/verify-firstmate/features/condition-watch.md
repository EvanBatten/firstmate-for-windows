# Condition watch

The captain can say "do X as soon as Y is true" and walk away.
Firstmate arms a watch that checks the condition by itself, runs the action once the condition holds, and tells firstmate it happened, without anyone sitting and polling.

## Sub-features

- `watch-arm` arms a condition and its action.
- `watch-registered` lists the armed watch as a registered source, and starts it on reconcile.
- `watch-holds` does not run the action before the condition is true.
- `watch-fires` runs the action once the condition holds.
- `watch-tells` puts a notification in firstmate's queue.
- `watch-retire` retires the watch.

## How to get to it (user POV)

- The captain asks for something to happen as soon as a fact becomes true, and firstmate runs `bin/fm-procevent-when.sh arm <name> --interval <secs> --stable <n> --deadline <secs> --condition <command...> --action <command...>`.
- Firstmate checks what is armed with `bin/fm-procevent.sh list` and starts sources with `bin/fm-procevent.sh reconcile`.
- Firstmate meets the result when it runs `bin/fm-wake-drain.sh`.
- Firstmate retires a watch with `bin/fm-procevent-when.sh retire <name>`.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- Nothing else is needed: the condition is a file the script creates, and the action touches another file.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run condition-watch`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
  The armed interval is 2 seconds, and each of the two waits stops at 90 seconds.
- **Arm.** The script runs `bin/fm-procevent-when.sh arm probe --interval 2 --stable 1 --deadline 180 --condition test -f <flag> --action touch <marker>`.
  It succeeds, and `bin/fm-procevent.sh list` names `when-probe`.
- **Start.** The script runs `bin/fm-procevent.sh reconcile`.
  It succeeds, and the marker file does not exist yet.
- **Make the condition true.** The script creates the flag file and waits up to 90 seconds.
  The marker file appears.
- **Be told.** The script runs `bin/fm-wake-drain.sh` until it prints a `procevent` line, for up to 90 seconds.
- **Retire.** The script runs `bin/fm-procevent-when.sh retire probe`.
  It succeeds.
- **Proof.** Read `condition-watch/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- The watch is a real background process with its own 180 second deadline, so an interrupted run ends by itself.
- The action and the notification land at different moments, which is why the script waits for each separately.
  A hand drive that checks both at once will see a false failure.
- Only a file-exists condition and a `touch` action are driven here.
  A condition that needs the network, or an action that changes a project, is not proved by this script.
