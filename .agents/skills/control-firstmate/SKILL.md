---
name: control-firstmate
description: >-
  Write a firstmate session trace and prove or disprove a feature claim with one Node command.
  Load before writing or running tools/fm-control traces, and when verify-firstmate needs a real session without the bash session-lib poll loop.
user-invocable: false
metadata:
  internal: true
---

# control-firstmate

A feature claim about a real firstmate session is proven or disproven by one command:

```
node tools/fm-control/drive.mjs run tools/fm-control/traces/<feature>.json
```

This skill is the agent-facing contract for that command.
[`tests/verification/session-lib.sh`](../../../tests/verification/session-lib.sh) remains the older bash session helper.
Do not source it from a trace.
Do not edit `bin/` to make a trace work.

Load this skill before writing a trace, before running `drive.mjs`, and when [`verify-firstmate`](../verify-firstmate/SKILL.md) needs a session-shaped proof.

## Trace

`trace.json` is a UTF-8 object:

```json
{
  "feature": "restart-primary",
  "steps": [
    { "say": "ahoy! add my project from {{projectOrigin}} ...", "until": "registered", "budgetSec": 600 },
    { "say": "", "until": "dispatched" },
    { "say": "$relaunch", "until": "dispatched" },
    { "say": "ahoy, I'm back. ...", "until": "relocked" },
    { "say": "", "until": "landed" },
    { "say": "", "until": "cleaned" }
  ]
}
```

`say` is captain text typed into the primary pane.
An empty `say` waits without typing.
`$relaunch` exits the primary, starts `claude` again in the same pane, and waits for ready before evaluating `until`.
`$exit` returns the pane to its shell.
Any other `$...` token is refused.

`{{projectOrigin}}` and `{{home}}` are the only interpolations.
The driver seeds a throwaway `greeter` origin and substitutes those values.

`until` is a closed catalog of home-record predicates.
Unknown tokens, `pong`, `bypass permissions on`, and a bare lock (`lock`, `lock.held`) are refused with exit 2 before any herdr call.
A trace whose every `until` only proves startup is refused the same way.

| `until` | True when the throwaway home shows |
| --- | --- |
| `registered[:name]` | `data/projects.md` has `- name ` and `projects/name/.git` exists (default `greeter`) |
| `dispatched` | at least one `state/*.meta` |
| `meta-count:N` | at least N task meta files |
| `kind:scout` or `kind:ship` | some meta has that `kind=` |
| `status-verb:done\|blocked\|working\|paused` | some `state/*.status` line begins with that verb |
| `reported[:needle]` | some `data/*/report.md` is non-empty and matches the needle (default `greet`) |
| `report-exists` | some report file is non-empty |
| `promoted` | some meta is `kind=ship` or `data/*/ship-instructions.md` is non-empty |
| `relocked` | `state/.lock` exists and differs from the identity captured at `$relaunch` (or at first ready) |
| `landed[:name]` | `projects/name` `main` differs from the seeded sha |
| `git-ahead[:name][:n]` | same comparison; `n` defaults to 1 |
| `cleaned` | no `state/*.meta` remains (`no-meta` and `home.clean` are aliases) |
| `watcher-armed` | the home's watcher pid is alive and the beacon is younger than 300s |

`pass` is true only when the last `until` holds.
What the primary prints is evidence, not a claim.

## Run

The driver clones this checkout into a throwaway home, starts one Herdr workspace, launches `claude` in that pane's own shell (no Git Bash login hop), types each `say`, and waits on `fs.watch` plus a short deadline tick.
A dead primary fails the current step at once.
The process closes only the workspace and session it created.

Stdout is one JSON object:

```
{feature, wallMs, pass, readyMs, predicateMs, steps:[{until, ms, ok}], overhead:{herdrCalls, spawns}}
```

Exit 2 means the trace was refused.
Exit 0 means a result object was printed, including `pass: false`.

Shipped traces:

- [`tools/fm-control/traces/restart-primary.json`](../../../tools/fm-control/traces/restart-primary.json) matches [`tests/verification/restart-primary.verify.sh`](../../../tests/verification/restart-primary.verify.sh).
- [`tools/fm-control/traces/scout-report.json`](../../../tools/fm-control/traces/scout-report.json) matches the scout session.

`FM_CONTROL_MODEL` selects the primary model (default `sonnet`).
`FM_CONTROL_SOCKET` attaches to an already-running Herdr socket and must not spawn `herdr` for status.
`CLAUDE_CODE_OAUTH_TOKEN` is passed into the pane environment; if it is empty and `CLAUDE_CODE_OATH_TOKEN` is set, the driver exports the OAuth name from that value.
Never echo, log, or commit either value.

## Plug-in to verify-firstmate

[`verify-firstmate`](../verify-firstmate/SKILL.md) still owns the behavior inventory, doctor, and the bash suite.
A session-shaped inventory row is proven when a real primary in a throwaway home leaves the catalog records this skill names.

Prefer this driver over `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run <feature>` when the feature already has a trace, or when you are writing the first trace for a session feature.
Keep the bash script as the compatibility path until its claims are expressed as a trace.

Portable proof of the driver itself is `node --test tools/fm-control/test/*.test.mjs`.
That lane uses fixture homes and a fake Herdr socket.
It does not spend model tokens and it does not prove a product feature.
