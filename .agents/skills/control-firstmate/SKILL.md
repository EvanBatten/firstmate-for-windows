---
name: control-firstmate
description: >-
  Drive one real Firstmate feature trace through a throwaway Herdr session and judge it from durable home records.
  Load when writing or running a tools/fm-control trace to prove or disprove a Firstmate feature with one command.
user-invocable: false
metadata:
  internal: true
---

# control-firstmate

Use this skill for the real-session portion of `verify-firstmate`.
The driver creates its own throwaway home and Herdr workspace, starts a real Claude primary, types each captain message once, and closes only resources it created.

Write a trace as:

```json
{
  "feature": "feature-name",
  "steps": [
    { "say": "captain message", "until": "project-registered:greeter", "budgetSec": 600 },
    { "say": "", "until": "task-count:1" },
    { "say": "$relaunch", "until": "lock-rotated" }
  ]
}
```

An empty `say` only waits.
`$relaunch` exits and starts the primary in the same pane without typing the token as captain text.
Use only the closed predicate catalog implemented by `tools/fm-control/lib/trace.mjs`.
Do not use pane prose or readiness banners as feature predicates.

From the branch under test, prove or disprove the claim with one command:

```sh
node tools/fm-control/drive.mjs run tools/fm-control/traces/<feature>.json
```

Exit `0` and `"pass":true` proves the trace's final durable predicate on this host.
Exit `1` with `"pass":false` disproves or times out the claim.
Exit `2` means the trace was rejected before Herdr started.
Keep the result JSON as `verify-firstmate` session evidence, and never treat a fake-Herdr test as feature proof.
