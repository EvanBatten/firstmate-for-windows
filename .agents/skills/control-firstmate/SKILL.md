---
name: control-firstmate
description: >-
  Drive one real firstmate session through a captain trace and measure how long each firmstate claim took to become true, with `node tools/fm-control/drive.mjs run <trace.json>`.
  Use when a verify-firstmate session needs to be driven or timed from an agent, when a firstmate behavior must be proven against a live primary in a throwaway home, or when a new session-tier feature needs a trace instead of a shell script.
  Traces are JSON, claims come from a closed catalog of home-record predicates, the primary's own words are never a claim, and the driver refuses a trace that only proves startup before it touches Herdr.
user-invocable: false
metadata:
  internal: true
---

# control-firstmate

`tools/fm-control/drive.mjs` is the session driver.
It clones the checkout into a throwaway home, opens one Herdr pane it owns, starts a real `claude` primary from that pane's own shell, types the captain lines of a trace into it, and waits for each step's claim to hold on the home's own records.
One JSON object on stdout says what held, how long each claim took, and what the driver itself cost.

The driver writes a throwaway `CLAUDE_CONFIG_DIR` inside the home with `hasCompletedOnboarding`, `bypassPermissionsModeAccepted`, project trust, and a theme settings file, then passes that directory into the pane env.
It does not mutate `~/.claude.json`.
`CLAUDE_CODE_OAUTH_TOKEN` (or `CLAUDE_CODE_OATH_TOKEN`, exported as the OAUTH name) is passed to the pane and is never written anywhere.

## Write a trace

```json
{
  "feature": "restart-primary",
  "project": "greeter",
  "steps": [
    { "say": "ahoy! add my project from {{projectOrigin}} as a local-only project called greeter ...", "until": "projects.registered:greeter", "budgetSec": 150 },
    { "say": "", "until": "tasks.count>=1 && backlog.inflight>=1", "budgetSec": 180 },
    { "say": "$relaunch", "until": "tasks.count>=1 && worker.alive", "budgetSec": 90 },
    { "say": "ahoy, I'm back ...", "until": "lock.rotated", "budgetSec": 60 },
    { "say": "", "until": "git.ahead:greeter>=1", "budgetSec": 420 },
    { "say": "", "until": "home.clean && tabs.clean", "budgetSec": 120 }
  ]
}
```

- `say` is captain text typed into the primary; `""` waits without typing; `$relaunch` exits the primary with `/exit` and starts it again in the same pane, the home and any worker untouched.
- `until` is one predicate or a `&&` conjunction from the closed catalog at the top of [`tools/fm-control/lib/predicates.mjs`](../../../tools/fm-control/lib/predicates.mjs); that file is the single owner of the catalog.
- `budgetSec` is the step's deadline; without it `FM_CONTROL_UNTIL_MS` (default 180000, three minutes) applies.
- Early restart-primary steps that should already be past ready (register, dispatch, relaunch, lock rotate) share a planned budget near ten minutes so a miss fails in minutes, not half an hour.
- The land step (`git.ahead`) is the only larger budget: the worker still has to implement and land the change.
- A passing run is expected around three minutes; the budgets are miss ceilings, not the target duration.
- `{{projectOrigin}}` is the bare origin of a throwaway project seeded with one commit before launch, named by `project` (default `greeter`); `{{home}}` is the throwaway home's path.
- `pong`, `bypass permissions on`, and a trace whose only claims are `lock.held` are refused with exit 2 before any Herdr call: they prove the harness started, not that firstmate did anything.
- Pane text is never a claim; a captain line that made the primary say the right thing but write nothing fails its step.
- A worker is dispatched when its record exists **and** its backlog item is In flight (`tasks.count>=1 && backlog.inflight>=1`); a record alone is a spawn still in progress, and relaunching over it lets Claude's exit kill the spawn, whose cleanup then removes the record.

Check a trace without spending anything with `node tools/fm-control/drive.mjs check <trace.json>`.
The shipped traces live under [`tools/fm-control/traces/`](../../../tools/fm-control/traces/).

## Run one

```
node tools/fm-control/drive.mjs run tools/fm-control/traces/restart-primary.json
```

Requirements: a logged-in `claude` on PATH, `herdr` 0.7.4 or newer (protocol 16), `git`, Node 20 or newer, and the same PATH a captain has.
The primary runs the model `FM_CONTROL_MODEL` (default `opus`).
With no `FM_CONTROL_HERDR_SESSION` and no default Herdr server running, the driver starts a throwaway server under a random `fm-control-<hex>` session and stops it at the end; with a named session it attaches and starts nothing.
`FM_CONTROL_TRANSPORT=socket|cli|auto` picks how it speaks to Herdr: the Unix socket where Node can open it, the `herdr` binary spawned once per call where it cannot (Windows).
Keep that CLI transport; do not replace it with a socket-only client.

Exit codes: 0 every step held, 1 a step did not hold, 2 the trace was refused, 3 the environment failed (Herdr unusable, clone failed, primary never ready).

## Read the result

```json
{ "feature": "restart-primary", "wallMs": 0, "pass": true, "readyMs": 0, "predicateMs": 0,
  "steps": [ { "say": "...", "until": "...", "ms": 0, "ok": true, "reason": "...", "relaunchMs": 0 } ],
  "overhead": { "transport": "socket", "herdrCalls": 0, "spawns": 0, "herdrSpawns": 0, "gitSpawns": 0, "setupSpawns": 0, "cleanupSpawns": 0, "setupMs": 0, "closeMs": 0 },
  "evidence": "/tmp/fm-control-artifacts/restart-primary-<utc>" }
```

`pass` is true only when the last `until` held.
`readyMs` is the first launch, `predicateMs` the total time spent waiting for claims, and the rest of `wallMs` is the driver: setup, typing, relaunch, and cleanup, which `overhead` breaks down.
Each step's `reason` names the first atom that decided it, so a failed step reads as `home.clean && tabs.clean: home.clean: task records remain: greeter-cli-g1`.
A dead primary fails its step at once, never at the budget.
A parked question fails the step only when that step's claim is still false.
Dead-primary and post-`/exit` detection use last-line shell prompts (`$`, `firstmate $`, `PS C:\path>`, `C:\path>`) plus the pid check; waits use `fs.watch` and do not poll Herdr every second.

The evidence directory keeps `result.json`, `captain.log`, a pane snapshot at every ready, dialog, relaunch and failure, the throwaway server's own log, and `home/state` plus `home/data` as the run left them.
`FM_CONTROL_EVIDENCE` names the directory; `FM_CONTROL_KEEP=1` leaves the home and pane in place for a look.

## How it plugs into verify-firstmate

A trace is the session tier of `verify-firstmate`: the same throwaway-home clone, the same real primary in Herdr, the same claims read from `state/`, `data/`, Herdr's tab list and the project's git refs, kept as evidence under the temp directory.
The shell scripts under `tests/verification/*.verify.sh` remain the inventory's `kind=entry` rows; this driver proves nothing to the inventory on its own.
A session script may call the driver instead of `session-lib.sh`'s poll loop when it wants deadlines, file-watch waits and a machine-readable timing record; wire that through `verify.sh` and `coverage.tsv` as `verify-firstmate` describes, and keep one owner for each feature's claims.
Report the result JSON verbatim, then the outcome in the captain's terms.

## Cleanup and safety

The driver closes only what it created: it exits its primary, stops the home's watcher, closes the tabs labelled for the home's own task records and any workspace it made, removes the treehouse pools whose worktrees live under the home and the task temp directories the records name, archives the records, deletes the home, and stops a Herdr server only when it started one.
A run that was killed can leave an `fm-control-<feature>-*` directory under the temp directory and, when it started its own server, an `fm-control-<hex>` Herdr session; remove either only when you know the run was yours and is over, and never stop a process by name.
It never writes to the checkout it clones and never merges anything; the primary under test does what firstmate does, in its own home.

## Tests

`node --test tools/fm-control/test/` (or `node --test tools/fm-control/test/drive.test.mjs`) runs without Herdr or Claude: refusals exit 2 with zero Herdr spawns, every predicate yields a literal boolean over fixture homes, and a scripted stand-in for the `herdr` binary drives whole traces, including the shipped `restart-primary` one.
The suite also checks that the throwaway onboarding config dir is created without writing `~/.claude.json`, and that the shell-prompt patterns match Git Bash, Linux cwd, and Windows shells.
