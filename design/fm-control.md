# Session control-cli

A long-lived Node process that drives a real firstmate session on Windows by speaking the herdr CLI and waiting on home-directory predicates.

This file is the design package.
It does not ship a driver.

`bin/fm-control.sh` remains the worker lifecycle plane (`interrupt`, `exit`, `relaunch`).
This tool is a different thing with a colliding directory name: a captain-session driver under `tools/fm-control/`.

## Usage

```
node tools/fm-control/drive.mjs run trace.json
```

`trace.json` is the only operand.
The process stays up for the whole run.
It prints one JSON object to stdout and nothing else on the success path.

Example trace:

```json
{
  "feature": "steer-worker",
  "steps": [
    {
      "say": "ahoy! add my project from ORIGIN as a local-only project called greeter. then ship one change...",
      "until": "registered"
    },
    {
      "say": "",
      "until": "dispatched"
    },
    {
      "say": "tell the worker to also add a fourth subcommand, shout...",
      "until": "steer_handled"
    },
    {
      "say": "",
      "until": "worker_done"
    },
    {
      "say": "keep the work. land it on main now, you have my approval, then clean up.",
      "until": "cleaned"
    }
  ]
}
```

An empty `say` means "do not type; wait for this predicate on the home as it already stands."
A non-empty `say` is typed into the primary pane through `herdr pane run`, then the process returns from that step only when `until` is true.

Stdout:

```json
{
  "feature": "steer-worker",
  "wallMs": 812340,
  "pass": true,
  "readyMs": 14220,
  "predicateMs": 798100
}
```

`pass` is true only when the last step's `until` predicate is true on the final home snapshot.
A timeout, a refused trace, a dead primary, or a herdr CLI failure prints the same shape with `pass` false.

## Trace contract

```ts
type Trace = {
  feature: string;
  steps: TraceStep[];
};

type TraceStep = {
  say: string;
  until: string;
};
```

`feature` is a non-empty string and becomes `result.feature`.
`steps` must be a non-empty array.
Every `until` must name a v1 home-directory predicate from the catalog below.

Reserved readiness tokens are not legal `until` values:

- `pong`
- `bypass permissions on`

A startup-only trace is invalid and must be refused before any herdr call.
That means every `until` is a reserved readiness token, or the trace has no feature predicate at all.
Ready is an implicit phase of `run`, not a step.

`say` may contain captain text, including slash commands the primary should read.
`say` is never a lifecycle verb for this driver.
`/exit`, relaunch, tab close, and workspace close are not encoded as `say` strings in v1.

## Timing

All clocks are `Date.now()` milliseconds on the one Node process.

| Field | Start | End |
| --- | --- | --- |
| `wallMs` | process start | stdout write |
| `readyMs` | process start | implicit ready (pane shows `bypass permissions on`, or a driver-owned ping that reads `pong`) |
| `predicateMs` | ready | last `until` true |

If ready never happens, `readyMs` is the time spent trying, `predicateMs` is `0`, and `pass` is false.
If ready happens and a later step times out, `predicateMs` is ready-to-timeout and `pass` is false.

Step budgets stay in the same order of magnitude as today's session scripts (`600`, `900`, `1200` seconds).
They are deadlines, not poll intervals.

## Types and not-implemented signatures

These are the public shapes the later driver must implement.
They are not shipped in this PR.

```ts
// tools/fm-control/types.mjs  (not implemented)

export type Trace = {
  feature: string;
  steps: TraceStep[];
};

export type TraceStep = {
  say: string;
  until: PredicateName;
};

export type PredicateName =
  | "registered"
  | "dispatched"
  | "three_dispatched"
  | "reported"
  | "promoted"
  | "steer_recorded"
  | "steer_handled"
  | "worker_done"
  | "all_done"
  | "relocked"
  | "watcher_armed"
  | "landed"
  | "cleaned";

export type DriveResult = {
  feature: string;
  wallMs: number;
  pass: boolean;
  readyMs: number;
  predicateMs: number;
};

export type HomeSnapshot = {
  home: string;
  projectsMd: string | null;
  projectGit: Record<string, { exists: boolean; mainSha: string | null }>;
  taskIds: string[];
  meta: Record<string, Record<string, string>>;
  status: Record<string, string>;
  inbox: Record<string, { pending: string[]; handled: string[] }>;
  reports: Record<string, string>;
  shipInstructions: Record<string, string>;
  lockText: string | null;
  watchLockPid: string | null;
  watchLockPidAlive: boolean;
  lastWatcherBeatMs: number | null;
  readyLockText: string | null;
  registeredMainSha: Record<string, string>;
  capturedAtMs: number;
};

export type HerdrIds = {
  session: string;
  workspaceId: string;
  paneId: string;
};

export type HerdrJson = unknown;

export declare function loadTrace(path: string): Trace;
export declare function assertRunnableTrace(trace: Trace): void;

export declare function snapshotHome(
  home: string,
  stamps?: { readyLockText?: string | null; registeredMainSha?: Record<string, string> },
): HomeSnapshot;
export declare function predicate(name: PredicateName): (snap: HomeSnapshot) => boolean;

export declare function waitUntil(
  home: string,
  name: PredicateName,
  budgetMs: number,
  stamps?: { readyLockText?: string | null; registeredMainSha?: Record<string, string> },
): Promise<HomeSnapshot>;

export declare function herdr(
  args: string[],
  opts?: { timeoutMs?: number },
): Promise<{ stdout: string; stderr: string; json: HerdrJson }>;

export declare function sessionOpen(home: string): Promise<HerdrIds>;
export declare function sessionReady(ids: HerdrIds, budgetMs: number): Promise<void>;
export declare function captainSays(ids: HerdrIds, text: string): Promise<void>;

export declare function run(tracePath: string): Promise<DriveResult>;
```

`predicate(name)` returns a pure function.
That function reads only the `HomeSnapshot` value.
It does not call herdr, does not spawn a process, and does not sleep.

`snapshotHome` reads the session home from disk.
It may read git ref files under `projects/*/.git`.
It may ask the OS whether `watchLockPid` is alive and store that as `watchLockPidAlive`.
It does not spawn `git`, `bash`, `pwsh`, `jq`, or `herdr`.
The driver stamps `readyLockText` at implicit ready and `registeredMainSha` the first time `registered` is true.
Those stamps ride on the snapshot value so predicates stay pure.

`waitUntil` rebuilds that snapshot and returns when `predicate(name)(snap)` is true, or rejects when `budgetMs` elapses.
It returns on the first true evaluation.
It does not sleep for five seconds between tries.

`herdr` spawns `herdr.exe` with `shell: false`.
It parses JSON with `JSON.parse`.
It never starts bash or pwsh.

## Module map

All of these paths are planned.
None of them exist yet.

```
tools/fm-control/
  drive.mjs        argv, loadTrace, run, print DriveResult
  types.mjs        the typedefs above
  trace.mjs        JSON load, startup-only refusal, unknown-until refusal
  snapshot.mjs     snapshotHome
  predicates.mjs   name -> pure (HomeSnapshot) => boolean
  wait.mjs         fs.watch on the home, debounce, waitUntil
  herdr.mjs        spawn herdr.exe, --session, JSON.parse
  session.mjs      clone/open/ready/say; Git Bash login once
  result.mjs       DriveResult clocking
```

Call graph for `run`:

1. `trace.mjs` refuses an invalid or startup-only trace.
2. `session.mjs` clones the code under test into a throwaway home and creates one herdr workspace.
3. `session.mjs` launches the primary in that pane and waits for implicit ready.
4. For each step, `session.mjs` types `say` when it is non-empty.
   `wait.mjs` then returns when `until` is true.
5. `result.mjs` writes one JSON object.
6. `session.mjs` closes only the workspace it created.

`bin/backends/herdr.sh` is not a module here and is not edited by this work.

## Herdr CLI this process speaks

The Node process calls `herdr.exe` directly.
Every call includes `--session <name>`.
`--cwd` is converted to a Windows path in Node.
Every other argument is passed verbatim so a leading `/` stays a slash command.

| Verb | When |
| --- | --- |
| `status --json` | once at start, refuse if the client is missing |
| `workspace create --cwd --label --no-focus --env ...` | session open |
| `workspace focus <id>` | before a `say` |
| `workspace close <id>` | session close |
| `pane run <pane> <text>` | Git Bash login once; primary launch once; each `say` |
| `pane read --source recent-unwrapped --lines N` | implicit ready; dead-primary check |
| `pane get <pane>` | optional dead-primary check |
| `pane send-keys <pane> <key>` | trust-prompt accept; exit-dialog Enter |
| `pane wait-output --regex --timeout` | only for implicit ready, never for a feature `until` |
| `tab list` / `tab close` | session close of tabs this run created |

Git Bash login happens once, at workspace create, the same way `tests/verification/session-lib.sh` does it today: `--env SHELL=<git-bash>` plus one `pane run` of `& '...\\bash.exe' --login`.
Later `pane run` calls type into that already-running pane.
They do not start another bash or pwsh.

## Home snapshot

`HomeSnapshot` is a value built from the throwaway `FM_HOME` the driver created.

| Field | Disk source |
| --- | --- |
| `projectsMd` | `data/projects.md` |
| `projectGit` | `projects/<name>/.git` presence and `refs/heads/main` (or packed-refs) |
| `taskIds` | `state/*.meta` basenames |
| `meta` | `key=value` lines in each `state/<id>.meta` |
| `status` | full text of each `state/<id>.status` |
| `inbox` | `state/<id>.inbox/*.msg` and `.../handled/*.msg` |
| `reports` | `data/<id>/report.md` |
| `shipInstructions` | `data/<id>/ship-instructions.md` |
| `lockText` | `state/.lock` |
| `watchLockPid` | `state/.watch.lock/pid` |
| `watchLockPidAlive` | OS liveness of that pid, recorded at snapshot time |
| `lastWatcherBeatMs` | `mtime` of `state/.last-watcher-beat` |
| `readyLockText` | `state/.lock` as it was at implicit ready, stamped by the driver |
| `registeredMainSha` | `projects/<name>` `main` sha when `registered` first became true |

What the agent prints is evidence, not a claim.
A feature `until` does not read pane text.

## Predicate catalog (v1)

Each name is a closed token.
Unknown names refuse the trace.

| `until` | True when the snapshot shows |
| --- | --- |
| `registered` | `projects.md` has a `- greeter ` row and `projects/greeter/.git` exists |
| `dispatched` | `taskIds.length >= 1` |
| `three_dispatched` | `taskIds.length >= 3` |
| `reported` | some `reports[id]` is non-empty and matches `/greet/i` |
| `promoted` | some `meta[id].kind === "ship"` or `shipInstructions[id]` is non-empty |
| `steer_recorded` | some inbox has a pending or handled `.msg` |
| `steer_handled` | some inbox has a handled `.msg` |
| `worker_done` | some status has a `done:` line, or `taskIds` is empty after a prior dispatch |
| `all_done` | every recorded task has a `done:` line, or `taskIds` is empty after a prior dispatch |
| `relocked` | `lockText` is present and differs from `readyLockText` |
| `watcher_armed` | `watchLockPidAlive` is true and `lastWatcherBeatMs` is younger than 300s |
| `landed` | `projects/greeter` `mainSha` is present and differs from `registeredMainSha.greeter` |
| `cleaned` | `taskIds` is empty |

`cleaned` in v1 is a home-directory fact: no `state/*.meta`.
Tab presence is a herdr fact and is not part of this predicate.
The driver may close tabs it created at session end through the herdr CLI.
That close is cleanup, not `pass`.

`watcher_armed` reads `watchLockPidAlive` from the snapshot.
The snapshot builder is what asked the OS.
The predicate still does not call herdr and does not spawn a process.

## Wait primitive

Today `session_wait` sleeps 5s inside 600/900/1200s budgets and, on every tick, starts `herdr` plus `jq` to see whether the primary died.

This driver breaks that.

- Watch `home` with `fs.watch({ recursive: true })`.
- Debounce file events for a few tens of milliseconds so a multi-file write becomes one snapshot.
- Rebuild `HomeSnapshot` and evaluate the pure predicate.
- Return on the first true value.
- Also evaluate once immediately, and once after each `say` returns.
- Treat a dead primary (pane back at a `$` prompt, or `pane get` gone) as a failed step, not as a sleep-and-retry.

A short debounce is not a five-second poll.
A deadline is not a sleep interval.

`pane wait-output` is allowed only for implicit ready.
Feature waits stay on the home watcher.

## Implicit ready

After `pane run` of `claude --dangerously-skip-permissions --model <model>`, the driver waits until the pane text contains `bypass permissions on`.
A folder already trusted may skip the trust prompt, which is fine.

`pong` is a reserved fallback the driver may use by typing a ping the primary is instructed to echo.
It is not a legal `until`.

A trace whose only claim is that ready happened is refused.

## Windows spawn rules

Windows is the host.

- One Node process for the whole `run`.
- `child_process.spawn(herdrExe, args, { shell: false, windowsHide: true })`.
- Resolve `herdr.exe` from `FM_CONTROL_HERDR` or `PATH`.
- Do not spawn `bash.exe`, `git-bash.exe`, or `pwsh.exe` for a herdr call, a snapshot, or a predicate.
- Do not spawn `jq`.
- Do not wrap `herdr.exe` in `bash -lc` or `pwsh -NoProfile -Command`.
- Do not set `MSYS2_ARG_CONV_EXCL` on a Node-spawned `herdr.exe`; that conversion is an MSYS bash problem this process does not have.
- Convert only `--cwd` to a Windows path.
- Never log, echo, or write `CLAUDE_CODE_OAUTH_TOKEN` or `CLAUDE_CODE_OATH_TOKEN`.

Git Bash still runs inside the herdr pane, once, as the pane's shell.
That is the session under test, not a per-call helper.

## What this replaces in the session scripts

`tests/verification/session-lib.sh` stays the current bash driver.
This design is the Windows replacement for its hot path, not a rewrite of those scripts in this PR.

| Current cost | Replacement |
| --- | --- |
| one `herdr` subprocess plus `jq` per query | Node `spawn` of `herdr.exe` and `JSON.parse`, and only when talking to herdr |
| Git Bash `--login` per pane as a repeated helper habit | one login at workspace create |
| `session_wait` `sleep 5` | `fs.watch` plus immediate re-eval |
| pane text as a feature claim | home-directory predicates |

## Rejections

- **Socket reducer.** Do not open the herdr control socket.
  Do not subscribe to `events.subscribe`.
  Do not reuse `bin/backends/herdr-eventwait.py`.
  Do not fold pane events into a local reducer that then invents predicates.
  The process speaks the herdr CLI.
- **Pane-owner that hides herdr.** Do not invent a private pane protocol, a fake multiplexer, or an API that wraps pane ids so callers never see herdr verbs.
  Workspace, pane, and tab ids stay herdr ids.
- **Per-call bash or pwsh.** No `bash -lc herdr ...` and no `pwsh -Command herdr ...`.
- **`jq` child.** Parse JSON in process.
- **Five-second `session_wait`.** Deadlines stay; the sleep loop does not.
- **Startup-only traces.** `until` of `pong` or `bypass permissions on` is invalid.
- **Pane-text feature predicates.** `session_idle`, `yielded`, and `woke` as defined in `session-lib.sh` / `supervision-wakes.verify.sh` read herdr or an observer tick file this driver does not keep.
  They are not v1 `until` names.
- **Lifecycle-as-say.** `/exit` plus relaunch is how `restart-primary` works today.
  v1 cannot drive that feature.
  A later step kind may add it; a `say` string must not pretend to.
- **Editing `bin/backends/herdr.sh`.** The firstmate herdr adapter is out of scope.
- **Implementing the driver in this PR.** Signatures only.
- **Replacing `bin/fm-control.sh`.** Worker interrupt, exit, and relaunch stay on that plane.
- **Driving a live captain home.** The driver creates a throwaway home, same rule as `tests/verification/session-lib.sh`.

## Out of v1

- `restart-primary` (needs a relaunch step, not only `say` / `until`).
- `supervision-wakes` claims that require `ticks.tsv` or pane `agent_status`.
- Tab-empty as part of `cleaned`.
- Closing other people's workspaces.
- A tmux backend.
- A socket subscriber "fast path."

## Owner

This file is the owner of the control-cli contract.
A later implementation PR adds `tools/fm-control/*.mjs` and tests that drive those files as the public interface.
Those tests must not assert implementation-source bytes.
