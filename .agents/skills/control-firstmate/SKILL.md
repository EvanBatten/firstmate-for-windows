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

The driver gives Claude an isolated `CLAUDE_CONFIG_DIR` inside the throwaway home.
It marks onboarding, folder trust, and the bypass-permissions disclaimer complete and selects a theme before launch, then passes `CLAUDE_CODE_OAUTH_TOKEN` only through the pane environment.
Never persist, print, or add that token to result evidence.
Do not replace this setup with prompt keystrokes.

Repository copies dereference the tracked `.claude/skills` link so the throwaway home does not require Windows symlink privileges.
Herdr 0.7.4 protocol 16 accepts one request per control connection, so the driver opens a fresh connection for each request and keeps only the event subscription open.
On Windows, Herdr 0.8.2 implements local IPC with protected named pipes instead of AF_UNIX.
Linux results do not prove that Node can consume the Windows `status.server.socket` value; rerun the same trace on a Windows host before recording Windows support as proven.

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
