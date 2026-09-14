# firstmate for Windows

### Talk to one agent. Ship with a crew. On Windows.

This is a Windows port of [firstmate](https://github.com/kunchenguid/firstmate), an agent distro for running a crew of coding agents.
Upstream targets macOS and Linux.
This fork carries the smallest set of measured patches that run the same distro on native Windows 11 under Git Bash, with [Herdr](https://herdr.dev) as the session backend.
It is a separate project from upstream; see [Credit and upstream](#credit-and-upstream).

## What it is

One coding agent is easy to run.
Three tasks in parallel turn you into a tab juggler, copying context between sessions and losing track of which terminal had the failing test.

With firstmate you talk to one agent, the first mate.
It spawns autonomous crewmates in a visible session backend, gives each its own git worktree, supervises them, and hands you finished PRs, approved local merges, or investigation reports.

An agent distro is a directory of instructions, skills, tooling, policies and state conventions that turns a general-purpose agent into a specialized one.
The cloned repo is the whole install: launch a supported harness inside it, and that agent becomes your first mate and you its captain.

## What the port changes

Each fix sits behind a capability check instead of a `uname` test, so macOS and Linux behave exactly as upstream.

- Line endings: Git for Windows would check out every `bin/*.sh` with CRLF, and a shebang ending in CR names no interpreter. The tracked `.gitattributes` prevents it.
- Process identity: MSYS `ps` has no `-o`, a bash started by a native process reports PPID 1, and `kill -0` cannot see a Win32 pid. `bin/fm-proc-lib.sh` answers "what process is this, and is it alive" for every caller.
- The Herdr CLI: socket paths arrive as `C:\...`, MSYS rewrites arguments that start with `/`, and a native `jq.exe` ends each record with CR LF.
- The crewmate pane: Herdr opens a Windows shell and `tab create` has no shell flag, so the adapter starts Git Bash itself.
- Path comparison: `git rev-parse --show-toplevel` answers `C:/...` where `pwd -P` answers `/c/...`, with different case. `bin/fm-path-lib.sh` owns that comparison.
- Test fixtures: four fixture assumptions made the suite unrunnable here, and two of them were wrong on Linux too.
- The session lock: MSYS cannot implement POSIX `exec`, so the lock records the harness session id beside the pid.
- Private state: Git Bash mounts are `noacl` and store no POSIX mode. `bin/fm-private-lib.sh` checks whether a path's filesystem can carry a mode, keeps the exact check where it can, and records a waiver where it cannot.
- Scripts started from node: Windows node cannot run a shebang script (`spawn()` fails with `EFTYPE`), so every such site runs `bash` with the script as its argument.

[docs/windows/measurement.md](docs/windows/measurement.md) has the command and output behind each of these, and [docs/windows/README.md](docs/windows/README.md) is the entry point to the port's documentation.

## What works

Measured on Windows 11 26200 and Git Bash 5.2.37 (MINGW64), with Herdr 0.8.2, treehouse 2.3.0 and a native `claude.exe`.

The full captain loop has run end to end three times on a real machine: register and clone a project, spawn a crewmate into a treehouse worktree on Herdr, answer its trust dialog, take its PR, merge on the captain's word, and tear down.

A few things use upstream's fallbacks.
Windows Python has no `socket.AF_UNIX`, so the watcher polls instead of subscribing to events.
There is no `lsof`, so the stale git-lock proof refuses rather than guesses.
Presentation workspace ordering and the [wedge alarm](docs/wedge-alarm.md) notifier are best effort.

The extension host, `bin/fm-extension.mjs`, still asserts exact file modes, so extension capture refuses on a `noacl` mount and its suites skip on Windows ([#36](https://github.com/EvanBatten/firstmate-for-windows/issues/36)).
Suite counts and the classification of every remaining red are in the ledger under "Integration".

## Features

- One liaison: you talk only to the first mate, which dispatches, supervises, and brings you only the decisions that are yours.
- A visible crew: each crewmate works in its own Herdr tab that you can watch or type into.
- Disposable worktrees: each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) worktree, so parallel work on one repo never collides.
- Ship and scout tasks: ship tasks deliver authorized changes, and scout tasks leave standalone investigation reports.
- Project modes: each project ships through `no-mistakes`, `direct-PR` or `local-only`, with an optional `+yolo` merge flag.
- Second mates: optional persistent helpers that run from isolated homes with their own `FM_HOME`, state, projects and session lock, locally or [remotely](docs/remote-secondmates.md).
- Low-token supervision: a bash watcher wakes the first mate only when something needs it. On Windows it polls.
- A project boundary: the first mate stays read-only over your projects outside the narrow operations in [hard rule 1](AGENTS.md#1-identity-and-prime-directives), and crewmates make every other change.
- Restart-proof: all state lives on disk and in the session backend, so a new session reconciles and carries on.

[docs/architecture.md](docs/architecture.md) covers each one in detail.

## Quick start

### Requirements

- Windows 11 with [Git for Windows](https://gitforwindows.org).
- A verified primary agent harness. The port is measured against Claude Code with a native `claude.exe`.
- The GitHub CLI, authenticated with `gh auth login`.
- [Herdr](https://herdr.dev) protocol 14 or newer, plus `jq`, `node` and treehouse. Herdr is the backend here because tmux, upstream's reference backend, is not available; see [docs/herdr-backend.md](docs/herdr-backend.md).

The first mate detects missing tools and installs the supported ones after you approve.

### Install and launch

Two settings have to be in place before you clone, because no repository file can set them:

- `core.symlinks` must be true. Git for Windows defaults it to false, which checks out `.claude/skills` as a 17-byte text file and leaves your harness with no skills.
- `MSYS=winsymlinks:nativestrict` must be in your environment, or the test harness cannot build its fixtures.

```sh
gh auth login
git clone -c core.symlinks=true https://github.com/EvanBatten/firstmate-for-windows
cd firstmate-for-windows
```

Launch your harness from Git Bash, and `AGENTS.md` takes over:

```sh
claude
```

Then ask for work:

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/ and spawns two isolated workers in Herdr.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

## How it works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   Herdr tabs, one per task
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree, or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

The supervision engine, worktree isolation, second mates, dispatch profiles, project modes, fleet sync and self-update are all in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Claude and grok use the slash form below; codex uses the same names with `$`, as in `$afk`.

| Skill              | What it does |
| ------------------ | ------------ |
| `/afk`             | Away-mode supervision: routine notifications are handled in bash, captain-relevant events arrive as batched digests, and a stuck delivery raises an alert. |
| `/ahoy`            | Recaps what happened since your last message, then walks you through open decisions one at a time, most important first. |
| `/bearings`        | A four-section digest of fleet and second-mate state. `/bearings file` also writes today's report to `data/`, and `include PRs` adds live PR detail. |
| `/updatefirstmate` | Fast-forwards firstmate and its second mates to origin, then reloads instructions. |
| `/stow`            | Saves the session's durable knowledge and open work records, curates startup memory within its budget, and reports what is safe to reset. |

These, and the agent-only reference skills that load at the triggers named in [`AGENTS.md`](AGENTS.md), live in `.agents/skills/`.
Each carries `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide it, because it only makes sense inside a firstmate home.
The public `skills/` directory holds standalone skills for any project; today that is `skills/stow`, which shares no code with the internal `/stow`.

## Documentation

For the Windows port:

- [docs/windows/README.md](docs/windows/README.md): entry point and branch layout.
- [docs/windows/measurement.md](docs/windows/measurement.md): the findings ledger, with every measurement and the classification of everything still red.
- [docs/windows/prs.md](docs/windows/prs.md): how the port's history splits into independently reviewable branches.
- [docs/herdr-backend.md](docs/herdr-backend.md): Herdr setup, safety boundaries and limits, including its Windows section.

For firstmate itself:

- [docs/architecture.md](docs/architecture.md) and [docs/configuration.md](docs/configuration.md): how it works, and every setting, environment variable and supported harness.
- [docs/scripts.md](docs/scripts.md): the `bin/` toolbelt.
- [docs/remote-secondmates.md](docs/remote-secondmates.md), [docs/wedge-alarm.md](docs/wedge-alarm.md) and [docs/turnend-guard.md](docs/turnend-guard.md): remote second mates, the away-mode alert, and the backstop that keeps a session from ending unsupervised.
- [docs/documentation-audiences.md](docs/documentation-audiences.md): who each document is for, and the check that enforces it.
- [`AGENTS.md`](AGENTS.md): the always-loaded operating contract. [CONTRIBUTING.md](CONTRIBUTING.md): workflow, conventions and tests.

Upstream's other session backends are still in the code, but only Herdr runs on Windows: [tmux](docs/tmux-backend.md), the reference backend on macOS and Linux, and the experimental [zellij](docs/zellij-backend.md), [orca](docs/orca-backend.md) and [cmux](docs/cmux-backend.md) backends.

## Credit and upstream

firstmate was created by [Kun Chen](https://github.com/kunchenguid) and lives at [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
The design is his; this port is a platform layer under it.
On macOS or Linux, use upstream directly.

This repository is maintained separately and does not speak for upstream.
Port work that might suit upstream is written up as self-contained branches in [docs/windows/prs.md](docs/windows/prs.md), but none of it has been sent.

## Contributing and license

Contributions are welcome; [CONTRIBUTING.md](CONTRIBUTING.md) has the workflow and how to run the tests.

MIT, see [LICENSE](LICENSE).
Copyright for the original work remains with Kun Chen, and the port is distributed under the same license.
