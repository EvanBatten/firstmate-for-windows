# fm-control

Design package only.
This document is the owner of the control-cli contract.
It does not implement `tools/fm-control/`.
It does not change product bash under `bin/`.

Audience: `maintainer-architecture`.
Status: proposed.
Implementation of the driver is a later change and is out of scope here.

## Why this exists

[`tests/verification/session-lib.sh`](../tests/verification/session-lib.sh) drives a real firstmate primary by spawning one `herdr` subprocess per query (`pane read`, `pane get`, `pane run`, `wait-output`, `tab list`).
That is the mac and tmux shape: a fork is cheap, so a poll loop that shells out every few seconds is acceptable.
Windows is the design center for this cli.
[`docs/windows/measurement.md`](../docs/windows/measurement.md) records that wall time is roughly ten times Linux because every process spawn crosses the MSYS and Win32 boundary.
A session wait that calls `timeout 30 herdr pane read` every two to five seconds pays that tax on every tick, then pays it again in the observer.
This candidate forbids that shape.

The replacement is one long-lived Node process, one or two Herdr control sockets, a pure reducer, and home-file predicates.
Events from the stream go in.
A `TraceState` comes out.
`send-text` happens only when the reducer reports a state transition that requires it.
Pass and fail are read from the throwaway firstmate home, never from pane text.

## Caller usage

```
node tools/fm-control/drive.mjs run trace.json
```

`trace.json` is a UTF-8 JSON object.

```json
{
  "feature": "restart-primary",
  "steps": [
    {
      "say": "ahoy! add my project from {{projectOrigin}} as a local-only project called greeter. then ship one change: add greet.sh with three subcommands, hello, bye and version, each printing one line, plus a README section that documents them. one commit on its own branch. use the opus model for the worker. once the worker is dispatched, leave that worker running in its own tab. do not background a wait. when it is done, verify the result by running it and land it on main; you have my approval. tell me when it is landed.",
      "until": "registered:greeter"
    },
    {
      "say": "",
      "until": "meta-count:1"
    },
    {
      "say": "__relaunch__",
      "until": "meta-count:1"
    },
    {
      "say": "ahoy, I'm back. carry on where we left off: when the greeter worker is done, verify its result and land it on main, you have my approval, then clean up and tell me.",
      "until": "lock-rotated"
    },
    {
      "say": "",
      "until": "git-ahead:projects/greeter:1"
    },
    {
      "say": "",
      "until": "no-meta"
    }
  ]
}
```

Stdout is one JSON object and nothing else.

```json
{
  "feature": "restart-primary",
  "wallMs": 812340,
  "pass": true,
  "readyMs": 41200,
  "predicateMs": 768100
}
```

`pass` is true only when the last step's predicate is true at stop.
An earlier step that held and a last step that did not hold is `pass: false`.
A rejected trace prints no stdout JSON.

Exit status:

| Code | Meaning |
| --- | --- |
| 0 | Run finished and `pass` is true |
| 1 | Run finished and `pass` is false |
| 2 | Trace rejected before any session work |
| 3 | Environment or driver failure after a valid trace was accepted |

Stderr may carry one diagnostic line on 2 or 3.
Stderr must never carry a token, a socket payload, or a pane dump that includes secrets.

## Trace schema

```
Trace = {
  feature: string,
  steps: Step[]
}

Step = {
  say: string,
  until: string
}
```

`feature` is a non-empty token used only as the result label and as the evidence directory name.
It is not a dispatch key and it does not select hidden behavior.

`steps` must contain at least one object.
`until` is a catalog predicate, not a pane regex.
`say` is captain text typed into the primary, with three reserved forms:

| `say` | Effect on transition into that step |
| --- | --- |
| non-empty ordinary text | one `send-text` of that text, then Enter |
| `""` | no send; the reducer only waits for `until` |
| `__relaunch__` | lifecycle effect: `/exit` the primary, confirm the background-work dialog if it appears, start `claude` in the same pane, wait for ready, then wait for `until` |

`{{projectOrigin}}` and `{{home}}` are the only interpolations.
They are substituted after the throwaway project is seeded and before the first reduce.
Unknown `{{...}}` tokens reject the trace.

## Timing

All four numeric fields are integer milliseconds from `process.hrtime.bigint()`.

| Field | Start | End |
| --- | --- | --- |
| `wallMs` | process start, before clone | process stop, after close |
| `readyMs` | process start | first transition into `phase: "ready"` |
| `predicateMs` | that same ready instant | first instant the last step's predicate is true, or stop if it never is |

`readyMs` is a driver-internal launch cost.
It may use stream evidence (native idle or done, or a one-shot output match for the trust dialog).
It is not a pass condition and it must not appear as an `until`.

If the last predicate never holds, `predicateMs` is still emitted and equals the wait from ready to stop.
`pass` stays false.

## What this is not

This cli is not [`bin/fm-control.sh`](../docs/agent-control.md).
That script is the product lifecycle plane for an already-recorded worker.
This cli is a sidecar that plays the captain: it types into a real primary and judges the home the primary writes.

This cli is not a second copy of [`tests/verification/session-lib.sh`](../tests/verification/session-lib.sh).
It does not source that file.
It does not wrap `herdr` in `timeout`.
It does not call `session_herdr`, `session_pane_text`, or `session_wait`.

This cli does not edit, wrap, or invoke product bash except as text the primary itself runs after a `say`.
The driver process must not `spawn` `bin/fm-*.sh`.

## Process model

Windows is the host the design is sized for.
Git Bash, Herdr, and a native `claude.exe` are the expected pane toolchain, matching the Windows 11 row in [`docs/verification/runtime-backends.md`](../docs/verification/runtime-backends.md).

Forbidden after attach:

- `herdr` as a child process per step, per tick, or per predicate
- `timeout herdr ...`
- `mkfifo` plus a short-lived [`herdr-eventwait.py`](../bin/backends/herdr-eventwait.py) per wait
- `pane read` polling to decide `until`
- any other one-query subprocess that exists only to sample Herdr

Allowed:

- one Node process for the whole `run`
- one stream socket that holds `events.subscribe` for the life of the run
- one control socket for request and response RPCs (`workspace.create`, `pane.run`, `pane.send_text`, `pane.send_keys`, `agent.get`, close)
- at most one attach spawn, and only when `HERDR_SOCKET_PATH` is empty: `herdr session list --json` or `herdr status --json` to resolve the socket, then never again
- `fs.watch` on the throwaway home's `state/` and `data/`
- the primary `claude` process, which lives in the Herdr pane and is started by a control-socket `pane.run`, not by a local `child_process.spawn("claude")`

CPython on Windows has no `AF_UNIX` (`bin/backends/herdr-workspace-move.py` already records that refusal).
The existing Python subscriber is therefore not a Windows transport.
Node 20 or newer is the required runtime because it can open the Win32 `AF_UNIX` socket Herdr publishes as `C:\Users\...\AppData\Roaming\herdr\herdr.sock`.

Sending over the socket also avoids MSYS path rewriting of a `/`-leading `send-text` payload, which is the defect documented in [`docs/windows/upstream/issue.md`](../docs/windows/upstream/issue.md).

## Event loop

```
                 +-------------------+
  herdr stream   |                   |   fs.watch(home)
  NDJSON lines --+--> reduce(state,e)+<-- HomeEvent
  (one socket)   |         |         |
                 +---------+---------+
                           |
                    { state, effect }
                           |
              effect is null unless a
              phase or stepIndex edge
                           |
              +------------+------------+
              |                         |
         send-text /               subscribe /
         send-keys /               close / stop
         __relaunch__
         (control socket)
```

The stream is edge-triggered.
Home files are the source of truth for predicates.
A home write that does not change the current `until` produces a new state object with the same `phase` and `stepIndex` and a null effect.
That is not a transition.

Level reconcile happens once per subscribe ack: the control socket issues `agent.get` for each known pane and feeds the results as ordinary events.
Missed edges during a reconnect are recovered the same way.
The reducer does not care which socket produced the event.

When `state/<id>.meta` first contains `herdr_pane_id=`, the reducer emits `{ type: "subscribe", paneId }`.
A second subscribe request on the stream socket, or a second stream connection from the same Node process, is allowed.
Spawning `herdr` to discover that pane is not.

## Reducer

`reduce` is a pure function.
It is the only function that may decide to send text.
It has no `child_process`, no `fs`, and no socket.

```
reduce(state: TraceState, event: Event): ReduceOut
```

`ReduceOut.effect` is non-null only when `phase` or `stepIndex` changed, or when a reserved lifecycle token is entered.
Replaying the same event against the returned state must yield a null effect.

### Phase machine

```
rejected  (pre-run; never enters the loop)

boot --> launching --> trusting --> ready --> awaiting --> passed
                         ^            |           |
                         |            |           +------> failed
                         |            +-- __relaunch__ --> relaunching --+
                         +-----------------------------------------------+
```

| Phase | Meaning | Who may send |
| --- | --- | --- |
| `boot` | sockets not yet subscribed | nobody |
| `launching` | `pane.run` of `claude` is in flight | nobody |
| `trusting` | folder-trust dialog is up | `send-keys` only (Down / Enter) |
| `ready` | primary can accept a captain `say` | the transition *out* of ready |
| `awaiting` | current `until` is false | nobody |
| `relaunching` | reserved `__relaunch__` lifecycle | `/exit` and pane.run, not a captain `say` |
| `passed` | last predicate is true | nobody |
| `failed` | timeout, primary exited, or blocked on a question | nobody |
| `rejected` | catalog or schema refusal | nobody; process never attached |

`send-text` of a step's `say` is emitted on the edge `ready -> awaiting` when `say` is ordinary non-empty text.
Empty `say` takes `ready -> awaiting` with a null send effect.
`__relaunch__` takes `ready -> relaunching` with a lifecycle effect, never a captain `send-text`.

A `blocked` native status on the primary during `awaiting` is `failed`.
The session-lib path that dismisses a question with Escape is not a default here.
A trace that needs to answer a question must `say` the answer as its own step after an `until` that is a home-file fact, not a pane prompt.

### Ready is not a predicate

Launch readiness may look at stream data:

- `pane.agent_status_changed` to `idle` or `done` after `claude` has started
- a single internal `pane.output_matched` for the trust dialog (`Yes, I trust this folder`) so `send-keys` can move the cursor
- a single internal match that the permissions banner is up, so `trusting -> ready` can fire

Those matches are driver-internal.
They must not be written as `until`.
A trace whose only `until` values are `pong` or `bypass permissions on` is rejected before attach, because that trace proves a harness banner and proves nothing about firstmate.

## Predicates

Predicates read the throwaway home.
They do not read Herdr, pane text, or git remotes other than the seeded project's own refs under that home.

`until` is a catalog token, optionally with `:` arguments.
Unknown tokens reject the trace at load.

| Token | Home read | True when |
| --- | --- | --- |
| `registered:<name>` | `data/projects.md` and `projects/<name>/.git` | a registry line for `<name>` exists and the clone directory is a git dir |
| `meta-count:<n>` | `state/*.meta` | the number of task meta files is `>= n` |
| `kind:<scout\|ship>` | `state/*.meta` | at least one meta file contains `kind=<value>` |
| `status-verb:<verb>` | `state/*.status` | a line begins with `<verb>:` (`done`, `blocked`, `working`, `paused`) |
| `lock-rotated` | `state/.lock` | the file exists and its bytes differ from the snapshot taken on entry to `__relaunch__` |
| `report-exists` | `data/*/report.md` | at least one scout report file exists and is non-empty |
| `file-contains:<rel>:<needle>` | `<home>/<rel>` | the file exists and contains the literal needle |
| `git-ahead:<rel>:<n>` | `git -C <home>/<rel> rev-list --count <base>..HEAD` | the count is `>= n`; `<base>` is the seed SHA captured at project seed |
| `no-meta` | `state/*.meta` | zero task meta files remain |
| `wake-empty` | `state/.wake-queue` | the file is missing or has no non-empty lines |
| `beacon-fresh` | `state/.last-watcher-beat` | the file exists and its mtime is younger than 300 s |

`git-ahead` is still a home-file predicate: it reads the project's git dir inside the throwaway home, not a Herdr pane and not a network remote.

A predicate function returns `{ ok: boolean, reason: string }`.
It must not throw on a missing file.
Missing means false.

The last predicate's `ok` at stop is the only input to `pass`.

## Rejections

Load-time refusals (exit 2, no stdout JSON, no Herdr attach):

1. JSON is not an object, or `feature` is missing, empty, or not a string.
2. `steps` is missing, not an array, or has length 0.
3. A step is not an object, or `say` / `until` is missing or not a string.
4. `until` is not in the catalog (including any unknown token).
5. The set of `until` values, after trim, is a subset of `{ "pong", "bypass permissions on" }`.
6. Any `until` is exactly `pong` or `bypass permissions on` (those strings are not in the catalog either; rule 5 is the named case the caller asked for).
7. `say` contains an unknown `{{...}}` interpolation.
8. `file-contains` or `git-ahead` uses a relative path that escapes the home (`..`, absolute, or a Windows prefix).
9. `meta-count` or `git-ahead` count is not a non-negative integer.
10. `kind` is not `scout` or `ship`.
11. `status-verb` is not one of `done`, `blocked`, `working`, `paused`.

Runtime refusals (exit 3, stdout JSON may be omitted):

- Node is older than 20
- `HERDR_SOCKET_PATH` is empty and the one allowed attach spawn cannot resolve a socket
- the control socket cannot connect
- the stream socket cannot subscribe
- the throwaway home cannot be created
- a `send-text` RPC fails after a transition that required it

A completed run never uses exit 2.
A rejected trace never attaches.

## Types

These typedefs are the contract.
They live in `tools/fm-control/lib/types.mjs` when implemented.
They are not implemented in this change.

```js
/** @typedef {'boot'|'launching'|'trusting'|'ready'|'awaiting'|'relaunching'|'passed'|'failed'|'rejected'} Phase */

/**
 * @typedef {object} Step
 * @property {string} say
 * @property {string} until
 */

/**
 * @typedef {object} Trace
 * @property {string} feature
 * @property {Step[]} steps
 */

/**
 * @typedef {object} Result
 * @property {string} feature
 * @property {number} wallMs
 * @property {boolean} pass
 * @property {number} readyMs
 * @property {number} predicateMs
 */

/**
 * Native Herdr line after subscribe, plus home and clock events.
 * fromStatus is empty on the wire; Herdr's stream is edge-triggered.
 *
 * @typedef {(
 *   | { kind: 'subscribed' }
 *   | { kind: 'agent_status', paneId: string, workspaceId: string, status: string, agent: string }
 *   | { kind: 'output_matched', paneId: string, pattern: string }
 *   | { kind: 'home', path: string, mtimeMs: number }
 *   | { kind: 'tick', nowMs: number }
 *   | { kind: 'rpc_ok', id: string }
 *   | { kind: 'rpc_err', id: string, message: string }
 *   | { kind: 'primary_exited' }
 * )} Event
 */

/**
 * @typedef {object} TraceState
 * @property {Phase} phase
 * @property {Trace} trace
 * @property {string} home
 * @property {string} feature
 * @property {number} stepIndex
 * @property {boolean[]} untilHeld
 * @property {boolean} lastUntilTrue
 * @property {string|null} primaryPaneId
 * @property {string|null} workspaceId
 * @property {string} lockBefore
 * @property {string} projectBase
 * @property {number|null} readyAtMs
 * @property {number|null} lastUntilAtMs
 * @property {number} startedAtMs
 * @property {string|null} failReason
 */

/**
 * @typedef {(
 *   | { type: 'send-text', paneId: string, text: string }
 *   | { type: 'send-keys', paneId: string, key: 'enter'|'escape'|'down' }
 *   | { type: 'pane-run', paneId: string, command: string }
 *   | { type: 'subscribe', paneId: string }
 *   | { type: 'relaunch' }
 *   | { type: 'stop', reason: 'passed'|'failed' }
 * )} Effect
 */

/**
 * @typedef {object} ReduceOut
 * @property {TraceState} state
 * @property {Effect|null} effect
 */

/**
 * @typedef {object} PredicateResult
 * @property {boolean} ok
 * @property {string} reason
 */
```

`TraceState.lastUntilTrue` is the last step's current `ok`.
`Result.pass` is a snapshot of that flag at stop, not a fold of every step.

## Not-implemented signatures

None of these files exist yet.
The signatures are the implementation boundary.

```js
// tools/fm-control/drive.mjs
export async function main(argv: string[]): Promise<number>

// tools/fm-control/lib/trace.mjs
export function loadTrace(jsonText: string): Trace
export function rejectTrace(trace: Trace): string | null
export function interpolate(trace: Trace, vars: { projectOrigin: string, home: string }): Trace

// tools/fm-control/lib/reducer.mjs
export function initialState(trace: Trace, home: string, startedAtMs: number): TraceState
export function reduce(state: TraceState, event: Event): ReduceOut

// tools/fm-control/lib/predicates.mjs
export function parseUntil(until: string): { token: string, args: string[] }
export function evaluateUntil(home: string, until: string, ctx: { lockBefore: string, projectBase: string, nowMs: number }): PredicateResult

// tools/fm-control/lib/herdr-socket.mjs
export function connectControl(socketPath: string): Promise<ControlSocket>
export function connectStream(socketPath: string, paneIds: string[]): Promise<AsyncIterable<Event>>
export function sendText(sock: ControlSocket, paneId: string, text: string): Promise<void>
export function sendKeys(sock: ControlSocket, paneId: string, key: 'enter'|'escape'|'down'): Promise<void>
export function paneRun(sock: ControlSocket, paneId: string, command: string): Promise<void>
export function agentGet(sock: ControlSocket, paneId: string): Promise<Event>
export function resolveSocketPath(env: NodeJS.ProcessEnv): Promise<string>

// tools/fm-control/lib/home-watch.mjs
export function watchHome(home: string): AsyncIterable<Event>

// tools/fm-control/lib/effects.mjs
export function applyEffect(effect: Effect, ctx: { control: ControlSocket, stream: StreamHandle, state: TraceState }): Promise<Event[]>

// tools/fm-control/lib/result.mjs
export function resultOf(state: TraceState, stoppedAtMs: number): Result
```

`reduce` must remain importable from a unit test that never opens a socket.
`rejectTrace` must remain importable from a unit test that never creates a home.

## Module map

```
tools/fm-control/
  drive.mjs              argv, seed home, attach once, merge streams, print Result
  lib/types.mjs          JSDoc typedefs above
  lib/trace.mjs          load, reject, interpolate
  lib/reducer.mjs        initialState, reduce
  lib/predicates.mjs     catalog parse and home-file evaluate
  lib/herdr-socket.mjs   NDJSON JSON-RPC, subscribe, send-text, no CLI after attach
  lib/home-watch.mjs     fs.watch on state/ and data/ -> HomeEvent
  lib/effects.mjs        apply one Effect over the control socket
  lib/result.mjs         TraceState -> Result
```

`drive.mjs` may create the throwaway home, seed the bare origin, and interpolate the trace.
It then attaches, launches, and forwards events.
It must not decide that a step has held.
Only `reduce` plus `evaluateUntil` decide that.

Colocated tests, when a later change implements the driver, belong next to this tree as `tools/fm-control/*.test.mjs` or under `tests/` as a Node runner that imports `reduce` and `rejectTrace`.
Those tests are not in this change.

## Wire

Verified against Herdr protocol 16+ (`docs/verification/runtime-backends.md`, `herdr 0.7.5` schema):

```
kinds: pane.output_matched, pane.agent_status_changed, pane.scroll_changed
```

Stream request, newline-delimited JSON, same shape as [`bin/backends/herdr-eventwait.py`](../bin/backends/herdr-eventwait.py):

```json
{
  "id": "fm-control-subscribe",
  "method": "events.subscribe",
  "params": {
    "subscriptions": [
      { "type": "pane.agent_status_changed", "pane_id": "w1:p1" }
    ]
  }
}
```

Ack: `result.type === "subscription_started"`.
Event: `{ "event": "pane.agent_status_changed", "data": { "pane_id", "workspace_id", "agent_status", "agent" } }`.

Control methods this design needs, all on the second socket:

| Method | When |
| --- | --- |
| `workspace.create` | once, throwaway label, `--no-focus` equivalent |
| `pane.run` | launch `claude`, and `__relaunch__` |
| `pane.send_text` | ready to awaiting, ordinary `say` only |
| `pane.send_keys` | trust dialog and `/exit` confirm |
| `agent.get` | level reconcile after subscribe |
| `pane.close` / `workspace.close` | teardown of ids this run created |

Exact RPC names must be read from `herdr api schema --json` at implement time if they differ from the CLI verbs (`pane send-text` vs `pane.send_text`).
The design constraint does not change: those calls go on the open socket, not through a new `herdr` process.

`pane.scroll_changed` is ignored.
`pane.output_matched` is subscribed only for the internal ready and trust patterns, never for `until`.

## Home layout the driver creates

The driver builds a scratch directory, clones the worktree under test into `<scratch>/firstmate`, and treats that clone as `FM_HOME` for the pane.
It must not create a sibling `home/` directory.
[`tests/verification/session-lib.sh`](../tests/verification/session-lib.sh) already records that a primary finding a separate home next to the clone writes records where no claim looks.

The pane starts with the captain toolchain on `PATH` (`.tools`, treehouse, no-mistakes) the same way `session_pane_path` does, but the path is passed as a Herdr pane env through the control socket, not by spawning a shell from Node to probe Herdr.

Close closes only the workspace this run created and only tabs whose labels this run recorded in home meta.
It does not run `herdr` to list tabs if the home no longer has meta: `no-meta` already held, and leftover foreign tabs are not this run's to close.

## Example: rejected traces

```json
{ "feature": "ping", "steps": [{ "say": "ping", "until": "pong" }] }
```

Rejected: the only `until` is `pong`.

```json
{
  "feature": "banner",
  "steps": [
    { "say": "", "until": "bypass permissions on" }
  ]
}
```

Rejected: the only `until` is `bypass permissions on`.

```json
{
  "feature": "mixed-banner",
  "steps": [
    { "say": "ahoy", "until": "pong" },
    { "say": "", "until": "meta-count:1" }
  ]
}
```

Rejected: `pong` is not in the catalog.

## Example: accepted scout skeleton

```json
{
  "feature": "scout-report",
  "steps": [
    {
      "say": "investigate which subcommands greeter should have. add the project from {{projectOrigin}} as greeter. write a scout report. do not change the project.",
      "until": "kind:scout"
    },
    { "say": "", "until": "report-exists" },
    {
      "say": "the report is enough. promote that scout and ship greet.sh as specified in the report. land on main, you have my approval, then clean up.",
      "until": "kind:ship"
    },
    { "say": "", "until": "git-ahead:projects/greeter:1" },
    { "say": "", "until": "no-meta" }
  ]
}
```

`pass` is true only if `no-meta` holds at stop.
A report that exists while the task record remains is `pass: false`.

## Implementation bounds for the next change

- Do not implement the driver in the same change as this document unless the captain asks for that change by name.
- Do not edit `bin/` to make this cli work.
- Do not teach `session-lib.sh` to call this cli.
- When the driver is written, add portable tests that feed canned `Event` arrays into `reduce` and assert the effect sequence, including "no second send-text on a repeated home event".
- When the driver is written, add reject fixtures for the two named banner traces.
- Keep this document the owner of the schema and the reducer contract; patch it rather than restating it in a second README.

## Auth note for implementers

The dashboard secret name `CLAUDE_CODE_OATH_TOKEN` (missing U) is not what Claude Code reads.
Claude Code reads `CLAUDE_CODE_OAUTH_TOKEN`.
A host that has only the OATH name must export the OAUTH name from that value in the pane environment, never log either value, and never write either value into a trace, a result, or a commit.
This design does not start a Claude session of its own; only the pane primary does.
