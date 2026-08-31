# firstmate for Windows

### Talk to one agent. Ship with a crew. On Windows.

This is a Windows port of [firstmate](https://github.com/kunchenguid/firstmate), an agent distro for running a crew of coding agents.
Upstream firstmate targets macOS and Linux.
This fork carries the smallest set of measured patches that make the same distro run on native Windows 11 under Git Bash, with [Herdr](https://herdr.dev) as the session backend.

It is a separate project from upstream, not a staging area for it.
See [Credit and upstream](#credit-and-upstream).

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it instantiates your first mate - and makes you the captain.

## What the port changes

Windows is not a hostile platform for this codebase so much as an unmeasured one.
The whole port is seven areas, each fixed behind a capability check rather than a `uname` test, so macOS and Linux behavior is unchanged:

- **Line endings at checkout.** Without a `.gitattributes`, the Git for Windows default rewrites all 151 `bin/*.sh` to CRLF, and a shebang ending `#!/usr/bin/env bash\r` names no interpreter. Nothing else in the port is measurable until this is fixed.
- **Process identity and liveness.** MSYS `ps` has no `-o`, a bash spawned by a native process reports PPID 1, and `kill -0` cannot see a Win32 pid. `bin/fm-proc-lib.sh` puts "what process is this, and is it alive" behind one library so harness ancestry and every liveness probe stop answering "dead".
- **The Herdr CLI on Windows.** Socket paths arrive as `C:\...`, MSYS rewrites `/`-leading arguments before `herdr.exe` sees them, and a native `jq.exe` ends every record CR LF so multi-row reads carry an interior CR.
- **The crewmate pane.** Herdr's `default_shell` on Windows is a Windows shell and `tab create` has no shell flag, so the adapter bootstraps Git Bash itself and carries a cwd emitter in through the environment.
- **Path form comparisons.** `git rev-parse --show-toplevel` answers `C:/...` while `pwd -P` answers `/c/...`, and the two disagree about case as well. `bin/fm-path-lib.sh` owns that comparison for every caller.
- **Test fixtures.** Four fixture assumptions made the suite unrunnable here, two of which were wrong on Linux too.
- **Session-lock identity.** MSYS cannot implement POSIX `exec`, so a hook's ancestry walk names no harness and tokenless watcher continuity never fires. The lock now records the harness session id beside the pid.

The findings ledger behind every one of those rows, with the exact command and output, is in [docs/windows/measurement.md](docs/windows/measurement.md).
[docs/windows/README.md](docs/windows/README.md) is the entry point to the port's own documentation.

## What works, and what does not

Measured on Windows 11 26200, Git Bash 5.2.37 (MINGW64), against Herdr 0.8.2, treehouse 2.3.0, and a native `claude.exe`.

**Working end to end.**
The full captain loop has been driven three times on a real machine: register a project, clone it, brief and spawn a crewmate into a treehouse worktree on the Herdr backend, answer its trust dialog, take its PR, merge on the captain's word, and tear down.

**Degraded, with the existing fallback doing the right thing.**
Windows Python has no `socket.AF_UNIX`, so the watcher polls instead of subscribing to native events.
There is no `lsof`, so the stale git-lock proof refuses rather than guesses.
Presentation workspace ordering and the wedge-alarm notifier are best-effort.

**Still open.**
Every Git Bash mount is `noacl`, so POSIX modes are not representable: `mkdir -m 700` creates a 755 directory and exits 1, and `chmod 600` reads back 644.
33 of 151 `bin/*.sh` create or assert mode-700/600 private state, and each of those checks misfires.
That is the largest remaining gap, and it is what stops the guarded PR merge path from arming a merge poll.
The open rows are tracked in the findings ledger rather than hidden.

Verified suite counts on the merged tree, and the classification of everything still red, are in [docs/windows/measurement.md](docs/windows/measurement.md) under "Integration".

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own Herdr tab you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver authorized changes; scout tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag.
- **Optional secondmates** - opt in to persistent second mates that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock.
- **Event-driven, low-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you; on Windows it polls rather than subscribing, which is the same fallback upstream uses when native event push is unavailable.
- **Strict project boundary** - the first mate is read-only over your projects except for the narrow guarded and captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives); crewmates make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend; kill the session anytime and the next one reconciles and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- Windows 11, with [Git for Windows](https://gitforwindows.org) providing Git Bash.
- A verified primary agent harness. Claude Code with a native `claude.exe` is what this port is measured against.
- The GitHub CLI, authenticated through `gh auth login`.
- [Herdr](https://herdr.dev) protocol 14 or newer, plus `jq`, `node`, and treehouse.

tmux is the reference backend upstream and is not available here, so Herdr is the backend on Windows.
The first mate detects and offers to install supported missing tools after you approve.

### Two settings no repository file can express

Both are checkout-time Git behavior, so they have to be set before or during the clone:

- `core.symlinks` ships as `false` on Git for Windows, which checks the repo's one tracked symlink (`.claude/skills -> ../.agents/skills`) out as a 17-byte text file, and your harness is then shown zero skills.
- `MSYS=winsymlinks:nativestrict` must be in your environment, or the test harness cannot build its fixtures.

The tracked `.gitattributes` handles line endings on its own once you have cloned.

### Install and launch

```sh
gh auth login
git clone -c core.symlinks=true https://github.com/EvanBatten/firstmate-for-windows
cd firstmate-for-windows
```

Then launch your harness from Git Bash; `AGENTS.md` takes over from there:

```sh
claude
```

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/ and spawns two isolated workers in Herdr.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

## How It Works

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

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with an event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine notifications in bash, escalates captain-relevant events and bounded declared-external-wait rechecks as batched digests, and actively alerts if delivery gets stuck while you step away |
| `/ahoy`            | Recap visible session events since the prior real captain message plus visibly unanswered captain decisions, then guide the captain through any open decisions one at a time in agent-judged impact order; fall back to Bearings when invoked as the session's first real captain message |
| `/bearings`        | Generate a concise four-section chat digest from bounded local fleet and registered-secondmate state; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` when live PR enrichment is wanted |
| `/updatefirstmate` | Self-update the running firstmate and its secondmates to the latest from origin with fast-forward-only pulls, then re-read instructions and nudge secondmates |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered second mates, and report what is safe to reset |

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

### The Windows port

- [docs/windows/README.md](docs/windows/README.md) - entry point to the port's own documentation and branch layout.
- [docs/windows/measurement.md](docs/windows/measurement.md) - the findings ledger: every subsystem measured, the exact command and output behind each row, and the classification of everything still red.
- [docs/windows/prs.md](docs/windows/prs.md) - how the port's history splits into self-contained, independently reviewable branches.
- [docs/herdr-backend.md](docs/herdr-backend.md) - setup, safety boundaries, and limits for the Herdr backend, including its "Windows (Git Bash / MSYS)" section.

### firstmate itself

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the crew, supervision, worktrees, secondmates, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, the files you set, and harness support.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [`AGENTS.md`](AGENTS.md) - the distro's always-loaded operating contract and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

### Backends this port does not use

These are upstream's other session backends.
They are documented here because the code that serves them is still present, but only Herdr is exercised on Windows.

- [docs/tmux-backend.md](docs/tmux-backend.md) - the reference backend on macOS and Linux.
- [docs/zellij-backend.md](docs/zellij-backend.md), [docs/orca-backend.md](docs/orca-backend.md), [docs/cmux-backend.md](docs/cmux-backend.md) - other experimental backends.

## Credit and upstream

firstmate was created by [Kun Chen](https://github.com/kunchenguid) and lives at [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
Everything this fork is useful for is his design; the port is a platform layer under it.
If you are on macOS or Linux, use upstream directly - this fork has nothing to offer you.

This repository is maintained separately.
It is not a staging branch for upstream and does not speak for that project.
Port work that would make sense upstream is written up in [docs/windows/prs.md](docs/windows/prs.md) as self-contained branches, so it can be offered there if it is ever wanted, but nothing here has been sent and none of it is a pending contribution.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
Copyright for the original work remains with Kun Chen; the port is distributed under the same license.
