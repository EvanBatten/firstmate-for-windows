# fm-control

A Node control-cli that owns one Windows Herdr pane and drives a full firstmate session from a trace.

This file is the design package only.
The driver is not implemented in this pass.
`bin/` is not part of this design.

Audience: maintainers writing or reviewing `tools/fm-control/`.
This is not a captain-facing operator guide and not a replacement for [`docs/agent-control.md`](../docs/agent-control.md), which owns firstmate's in-session lifecycle verbs (`interrupt`, `exit`, `relaunch`).

## Usage

```
node tools/fm-control/drive.mjs run trace.json
```

`trace.json` is a feature drive, not a session-start probe.

```json
{
  "feature": "restart-primary",
  "steps": [
    {
      "say": "ahoy! add my project from <origin> as local-only greeter, then ship greet.sh ...",
      "until": "tasks.count>=1"
    },
    {
      "say": "$relaunch",
      "until": "lock.rotated"
    },
    {
      "say": "ahoy, I'm back. land the greeter work on main, you have my approval, then clean up.",
      "until": "git.ahead:greeter>=1 && home.clean"
    }
  ]
}
```

Stdout is one JSON object and nothing else:

```json
{
  "feature": "restart-primary",
  "wallMs": 1843201,
  "pass": true,
  "readyMs": 41200,
  "predicateMs": 1791000
}
```

`pass` is true only when the last step's `until` holds at the moment that wait returns.
An earlier step that times out, a primary that exits, or a primary that stops to ask a question makes `pass` false because the last predicate never holds.
`readyMs` is the time from process start to the first ready pane (claude.exe past the folder-trust dialog, firstmate lock written).
`predicateMs` is the sum of time spent in `until` polls after that first ready, including a later `$relaunch` ready wait.
`wallMs` is the whole run, including clone, pane create, close, and cleanup.

The command exits `0` when it printed a result object.
`pass: false` is still a completed run.
It exits non-zero only when the trace is rejected or the pane cannot be created.

```
node tools/fm-control/drive.mjs parse trace.json
```

Validates the trace and prints `{"feature":"...","steps":N}` without opening a pane.
A startup-only trace is rejected here too.

### What the caller does not pass

The caller does not pass a herdr session, pane id, or socket path.
The caller does not pass a poll interval or a herdr subcommand.
The driver creates the pane, starts `claude.exe` in that pane's pwsh, types captain lines, and judges the feature from the throwaway home's records.

### Host

The run host is Windows.
`process.platform` must be `win32`.
Herdr's pane shell is pwsh.
`claude.exe` is a native binary.
Git Bash is a tool the agent may spawn later; it is not the pane login.

Required on `PATH` at run: `node`, `herdr`, `claude` (resolving to `claude.exe`), `git`.
`cygpath` is not required.
`jq` is not required.
The driver is Node; it does not source `tests/verification/session-lib.sh`.

Environment:

- `FM_CONTROL_MODEL` - primary model (default `opus`).
- `FM_CONTROL_UNTIL_MS` - default per-step `until` budget (default `1200000`).
- `FM_CONTROL_READY_MS` - first-ready budget (default `180000`).
- `FM_CONTROL_HOME` - optional existing home to reuse; default is a fresh clone of the current checkout into the system temp directory.
- `FM_CONTROL_KEEP` - if `1`, leave the pane and home after the run.
- `CLAUDE_CODE_OAUTH_TOKEN` / `CLAUDE_CODE_OATH_TOKEN` - passed through to the pane environment when set.
  If `CLAUDE_CODE_OATH_TOKEN` is non-empty and `CLAUDE_CODE_OAUTH_TOKEN` is empty, the driver exports the OAuth name from the Oath value in the child environment only.
  Neither value is echoed, logged, written to a trace, or committed.

## Types

These types are the contract the implementation must keep.
They are not implemented in this pass.

```ts
export type Trace = {
  feature: string;
  steps: Step[];
};

export type Step = {
  say: string;
  until: string;
};

export type RunResult = {
  feature: string;
  wallMs: number;
  pass: boolean;
  readyMs: number;
  predicateMs: number;
};

export type HomeSnapshot = {
  lock: string | null;
  lockAtReady: string | null;
  projects: string;
  metas: string[];
  statusById: Record<string, string>;
  gitAhead: Record<string, number>;
};

export type Predicate = {
  name: string;
  eval(home: HomeSnapshot): boolean;
};

export type PaneId = string;
export type WorkspaceId = string;

export type HerdrRequest = {
  method: string;
  params?: Record<string, unknown>;
};

export type HerdrResponse = {
  result?: unknown;
  error?: { message: string };
};
```

### `until` language

`until` is a boolean expression over a `HomeSnapshot`.
It is not pane text and not a herdr agent-status string.

Grammar:

```
expr     := term ( "&&" term )*
term     := atom
atom     := "tasks.count>=" INT
          | "tasks.done>=" INT
          | "projects.has:" NAME
          | "projects.cloned:" NAME
          | "lock.held"
          | "lock.rotated"
          | "git.ahead:" NAME ">=" INT
          | "home.clean"
```

`NAME` is `[A-Za-z0-9._-]+`.
Whitespace around `&&` is allowed.
No other operators, no negation, no parentheses.

Meaning:

- `projects.has:NAME` - `data/projects.md` has a line matching `^- NAME `.
- `projects.cloned:NAME` - `projects/NAME/.git` exists.
- `tasks.count>=N` - number of `state/*.meta` files is at least N.
- `tasks.done>=N` - number of `state/*.status` files that contain a `^done:` line is at least N.
- `lock.held` - `state/.lock` exists and is non-empty.
- `lock.rotated` - `state/.lock` exists and differs from the identity snapshotted at first ready.
- `git.ahead:NAME>=N` - `git -C projects/NAME rev-list --count <seed>..main` is at least N.
  The seed is the `main` sha recorded when the throwaway project was seeded, or the `main` sha at first ready if the driver did not seed one.
- `home.clean` - no `state/*.meta` remains.

`lock.held` is a startup atom.
A trace whose every `until` is only `lock.held` (or is empty) is startup-only and is rejected at parse.

`say` is typed into the pane as captain text, except reserved verbs:

- `$relaunch` - do not type those characters.
  Exit the running `claude.exe` (`/exit`, confirm a background-work dialog if it appears), then start `claude.exe` again in the same pwsh pane.
  Wait until first-ready rules hold again before evaluating that step's `until`.
- `$exit` - type `/exit` and wait for the pwsh prompt.
  Used only when the trace itself wants the shell back; ordinary features use `$relaunch`.

Any other `say` beginning with `$` is rejected at parse.

### Not-implemented signatures

```js
// tools/fm-control/drive.mjs
export async function main(argv: string[]): Promise<number>;
export async function run(tracePath: string): Promise<RunResult>;
export function parseArgs(argv: string[]): { cmd: "run" | "parse"; tracePath: string };

// tools/fm-control/lib/trace.mjs
export function loadTrace(filePath: string): Trace;
export function validateTrace(trace: unknown): Trace;
export function isStartupOnly(trace: Trace): boolean;
export function parseUntil(expr: string): Predicate;

// tools/fm-control/lib/session.mjs
export class Session {
  constructor(opts: { feature: string; model: string; repoRoot: string });
  home: string;
  workspaceId: WorkspaceId | null;
  paneId: PaneId | null;
  readyAtMs: number | null;
  lockAtReady: string | null;
  projectSeeds: Record<string, string>;
  async open(): Promise<void>;
  async launchClaude(): Promise<void>;
  async ready(): Promise<void>;
  async say(text: string): Promise<void>;
  async relaunch(): Promise<void>;
  async waitUntil(expr: string, budgetMs: number): Promise<boolean>;
  async close(): Promise<void>;
}

// tools/fm-control/lib/home.mjs
export function snapshotHome(home: string, extra: {
  lockAtReady: string | null;
  projectSeeds: Record<string, string>;
}): HomeSnapshot;
export function pollHome(
  home: string,
  extra: { lockAtReady: string | null; projectSeeds: Record<string, string> },
  pred: Predicate,
  budgetMs: number,
): Promise<boolean>;

// tools/fm-control/lib/pane.mjs
export class Pane {
  constructor(client: HerdrClient, paneId: PaneId);
  async run(pwsh: string): Promise<void>;
  async type(text: string): Promise<void>;
  async sendKeys(key: string): Promise<void>;
  async read(lines?: number): Promise<string>;
  async agentStatus(): Promise<string>;
  async atPwshPrompt(): Promise<boolean>;
}

// tools/fm-control/lib/herdr-client.mjs  -- INTERNAL, not a public API
export class HerdrClient {
  static async connect(session?: string): Promise<HerdrClient>;
  async request(req: HerdrRequest): Promise<HerdrResponse>;
  async workspaceCreate(opts: { cwd: string; label: string }): Promise<{
    workspaceId: WorkspaceId;
    paneId: PaneId;
  }>;
  async workspaceClose(id: WorkspaceId): Promise<void>;
  async workspaceFocus(id: WorkspaceId): Promise<void>;
  async paneRun(id: PaneId, command: string): Promise<void>;
  async paneSendKeys(id: PaneId, key: string): Promise<void>;
  async paneRead(id: PaneId, lines?: number): Promise<string>;
  async paneGet(id: PaneId): Promise<{ agent_status?: string }>;
  async close(): Promise<void>;
}

// tools/fm-control/lib/clock.mjs
export function nowMs(): number;
export type Timers = { startMs: number; readyMs: number | null; predicateMs: number };
```

`HerdrClient` is imported only by `pane.mjs` and `session.mjs`.
`drive.mjs` does not import it.

## Module map

```
tools/fm-control/
  drive.mjs              CLI: run | parse; prints RunResult JSON
  lib/trace.mjs          load, validate, reject startup-only, parse until
  lib/session.mjs        owns one home and one pane for the life of the run
  lib/home.mjs           Node fs snapshot and poll of firstmate records
  lib/pane.mjs           type, keys, read, status for the one pane
  lib/herdr-client.mjs   internal; one cached herdr connection
  lib/clock.mjs          wall / ready / predicate timers
```

No `bin/` change.
No addition to `tests/verification/session-lib.sh` in this pass.
A later implementation pass adds colocated tests that drive `validateTrace` and `parseUntil` with fixtures, and a Windows opt-in run of `drive.mjs` against a real pane.

### `drive.mjs`

Parse argv.
Load the trace.
Reject startup-only.
Construct `Session`, call `open`, `launchClaude`, `ready`, then each step, then `close`.
Print `RunResult`.

`run` always creates a pane even when `parse` was enough to reject; `parse` is the cheap gate.

### `session.mjs`

This module is the owner.

`open`:

1. Create a scratch directory.
2. Clone the current checkout into `scratch/firstmate` (the throwaway home), same isolation rule as `tests/verification/session-lib.sh`: never start firstmate in the primary checkout.
3. Seed no project unless a later implementation helper is asked to; traces that need a local origin say so in `say` and the firstmate under test clones it.
4. Ask `HerdrClient` once to create a workspace labeled `fm-control-<feature>` with `--cwd` set to the home as a Windows path and `--no-focus`.
5. Do not set `SHELL` to Git Bash.
6. Do not type Git Bash `--login`.
7. Optionally set `--env FM_PANE_PATH=<win32 PATH>` so pwsh can see `claude.exe` and the axi tools; adopt it in the launch line the same way the herdr adapter already does for a PATH herdr drops on `tab create --env`.

`launchClaude`:

Send one pwsh command into the new pane:

```
if ($env:FM_PANE_PATH) { $env:Path = $env:FM_PANE_PATH }
& claude.exe --dangerously-skip-permissions --model <model>
```

Resolve `claude.exe` with Node (`where.exe claude` or `process.env.PATH`), never by hoping `claude` is a Git Bash function.
`cd` is unnecessary when the workspace `--cwd` is the home.

`ready`:

Poll pane text only for the folder-trust dialog (Down to Yes, Enter).
Poll the home for `state/.lock`.
First ready is the first moment both are true: trust is past and the lock file exists.
Snapshot `lockAtReady`.
Do not treat pane prose, a digest banner, or herdr `agent_status` as the ready claim.
`readyMs` stops here.

`say`:

If the text is `$relaunch`, call `relaunch`.
Otherwise dismiss a blocked question with Escape, focus the workspace, and `pane.run` the captain line as pwsh-received pane input (herdr `pane run` types it; it is not a new shell).

`waitUntil`:

Call `pollHome` with the parsed predicate.
If the pane returns to a pwsh prompt, fail the wait (primary exited).
If `agent_status` is `blocked` and the current `say` was not a reserved verb, fail the wait (unanswered captain question).
Those failures are safety, not claims.

`close`:

`/exit` if needed, stop a watcher pid recorded in the home if one exists, close only this run's workspace, and archive `state/` and `data/` next to the result when possible.
Do not close a workspace that existed before `open`.

### `home.mjs`

Node `fs` only.
Read `state/.lock`, `state/*.meta`, `state/*.status`, `data/projects.md`, and `git rev-list` under `projects/<name>`.
Poll interval is 1000 ms.
No `herdr`, no `bash`, no `grep` child.

This is the wait loop.
It is why the driver can type once and then leave herdr alone for minutes while a worker builds.

### `herdr-client.mjs`

Internal.
One instance per `drive.mjs` process.

Connect once:

1. Run `herdr status --json` a single time to learn the session name and control-socket path (Windows spelling `C:\Users\...\herdr.sock` is legal).
2. Open one Node socket to that path (`net.connect({ path })` on Node 24, which can use AF_UNIX on this Windows build).
3. Keep that socket for the run.

Every later pane or workspace call is one JSON request / one JSON response on that socket, the same newline-delimited shape `bin/backends/herdr-workspace-move.py` already uses:

```
{"id":"...","method":"<method>","params":{...}}\n
```

Allowed methods are only the ones `Session` and `Pane` need: workspace create/close/focus/list, pane run/send-keys/read/get, tab list/close if cleanup requires them.
No `subscribe`.
No `pane.agent_status_changed`.
No event buffer.

If the socket dies, reconnect once and continue.
If the reconnect fails, the run fails.
Do not open a second live socket while the first is up.
Do not spawn `herdr.exe` per step.

The one allowed extra CLI spawn after connect is a last-resort `herdr server` start when `status` reports no running server, issued once during `connect`, never from `waitUntil`.

`MSYS2_ARG_CONV_EXCL=*` is set on that first CLI spawn so a Git-Bash-hosted `node` cannot rewrite `/exit` or a leading-slash captain line.
After the socket is open, captain text never crosses a CLI argv.

## Run sequence

```
parse trace
  reject if startup-only
clone home
connect herdr (once)
create workspace + pane (pwsh)
launch claude.exe in that pwsh
ready (trust + lock)                 -> readyMs
for each step:
  say | $relaunch
  poll home until pred               -> add to predicateMs
close pane
print { feature, wallMs, pass, readyMs, predicateMs }
```

`pass` is `lastUntilHeld`.
It is not "every step held" restated as a score, and it is not "the pane looks good".

## Rejected designs

### Shell out to herdr for every step

`tests/verification/session-lib.sh` does this today: every `pane run`, `pane read`, `pane get`, `send-keys`, and observer tick is `timeout 30 herdr ...`.

On Windows that is a new `herdr.exe` process per call, plus MSYS argument conversion, plus a 30 s wrapper.
The observer already does it every 10 s for the whole session.
A feature wait of twenty minutes becomes hundreds of native spawns that are not the claim.

That shape also makes herdr the public API: every new step adds another argv list.
This driver does not export `herdr()` and does not call it from the wait loop.

### A socket event reducer

Protocol 16 can subscribe to `pane.agent_status_changed` over the control socket.
Firstmate's watcher already owns that path, and on this Windows box the Python AF_UNIX reader is degraded, so the product itself falls back to polling.

A driver that subscribed and reduced those edges into a state machine would:

- make pane `idle` / `done` / `blocked` the feature claim, which `session-lib.sh` already forbids (agent print and herdr status are evidence, not a claim);
- couple the control-cli to protocol 16 and to a Windows socket-event stack that this machine has already measured as degraded;
- turn `$relaunch` and trust-dialog keys into event-graph special cases.

The driver may hold one socket for request/response.
It does not subscribe, buffer edges, or treat a status transition as `until`.

### Git Bash `--login` as the pane bootstrap

The current session path types `& '<git bash>' --login` into pwsh, waits for a `$` prompt (up to 90 s), then types `cd ... && claude` through that login shell.

Session-start under Git Bash has cost minutes on this host: every script the primary runs is a MSYS fork, and `bin/fm-session-start.sh` is a tree of them.
The login hop adds a second userland before `claude.exe` exists.

This driver starts `claude.exe` as a child of the pane's pwsh.
Firstmate scripts still run as Git Bash tool processes inside Claude; that cost stays visible in `readyMs`.
The driver does not add a typed login shell around the pane.

### macOS tmux, one CLI subprocess per question

The mac design assumes tmux, a POSIX pane shell, and one CLI subprocess per question.
Windows is not that host.
This package does not wrap tmux and does not spawn a new control process per `say`.

### Pane-text predicates

`until` does not match composer text, digest banners, or "Yes, I trust this folder".
Those strings change between Claude releases.
Home records are the claim, the same rule as `tests/verification/session-lib.sh`.

## Relation to the existing session scripts

`tests/verification/session-lib.sh` remains the bash session helper for scripts that already source it.
This design does not delete it and does not edit `bin/`.

When the driver exists, a Windows feature drive should move to `drive.mjs` plus a `trace.json` so the wait loop stops paying a herdr spawn per tick.
`restart-primary` is the first intended trace: dispatch, `$relaunch`, carry on, last predicate `git.ahead:greeter>=1 && home.clean`.
