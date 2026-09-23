# Ship three changes in parallel

This is the loop the captain relies on, run as a real session.
He registers a project and asks for three independent changes in one message; three workers appear in their own Herdr tabs, each builds its change in its own isolated copy, firstmate checks each result, all three land on the project's main, and nothing is left behind.
It is a session: the code under test is cloned into a fresh home, a real firstmate primary runs there, and every claim is read from records, never from what the agent says.

## Sub-features

- `ships-register` registers a local-only project from a captain message and clones it into the home.
- `ships-dispatch` turns one request for three changes into three work items, three sets of instructions, three tabs and three isolated copies.
- `ships-done` sees each worker report its task done.
- `ships-land` lands all three on main with the captain's standing approval, the later two after a rebase, and the work does what was asked when run from main.
- `ships-cleanup` removes every tab, returns every copy, leaves no task record and leaves the home healthy.

## How to get to it (user POV)

- The captain, in the firstmate pane, asks for a project to be added and for several changes to ship in parallel, and states his approval to land them.
- Firstmate does the rest through `bin/fm-brief.sh`, `bin/fm-spawn.sh`, `bin/fm-merge-local.sh` and `bin/fm-teardown.sh`, supervised by the watcher between turns.
- The captain watches the workers in their tabs.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- `HERDR_ENV=1`, and `herdr`, `jq`, `claude`, `git`, `timeout`, `cygpath`, and `tar` are installed, with `claude` signed in.
  Without `HERDR_ENV=1` the script skips and says it is not inside a Herdr session.
- The primary checkout has a `.tools/` directory with the axi tools, and treehouse is installed; the session gives the clone the same toolchain.
- You accept that it spends model tokens and opens tabs the captain will see.
  Without `VERIFY_REAL_SESSION=1` the script skips, and a skip counts as unproven.

- **Drive the feature.** Run `VERIFY_REAL_SESSION=1 .agents/skills/verify-firstmate/verify.sh run ship-three-parallel`.
- **Start the session.** The script clones the code under test into a fresh home, opens a Herdr workspace labelled `fm-verify-three-ships`, starts `claude` there with the captain's toolchain on PATH, and gets it past the trust prompt.
- **Ask.** The script types one message: add the project as local-only, ship three named changes in parallel, approval to land them all.
- **Register.** `data/projects.md` gains a `greeter` line and `projects/greeter/.git` exists.
- **Dispatch.** Three `state/<id>.meta` records appear; each names a worktree that is a linked worktree other than the project's checkout, and a Herdr pane that exists.
- **Done.** Each `state/<id>.status` gains a `done:` line.
- **Land.** The project's bare origin has `main` three commits ahead of its start, and `greet.sh`, `farewell.sh` and `VERSION` from `main` do what was asked when run.
- **Clean up.** No `state/<id>.meta` remains and no tab opened for the session is still open.
- **Health.** The session ends with the health check every session gets: no lock takeover chain, no lock owner left, an empty acknowledged queue, no waiting note, no task record, a beacon that stayed fresh whenever work was in flight and the primary idle, and no tab left.
- **Proof.** Read `ship-three-parallel/transcript.txt`, the `panes/` snapshots of the primary and every worker, the `records/` snapshots of `state/` and `data/` over time, `ticks.tsv`, `captain.log`, `project-refs.txt` and `home-records.tar` in the evidence directory.

## Gotchas

- The primary's model is `opus` unless `VERIFY_SESSION_MODEL` says otherwise, so a run does not spend the captain's default model's quota.
  Workers use whatever firstmate resolves for them.
- The home lives under the system temp directory, which on this machine has two spellings (`/tmp` and the `AppData` path).
  That is the condition that exposed #82; a lock takeover chain in the health check is that defect, not this script's.
- Firstmate polls its workers itself inside one long turn when it chooses to, so this session does not prove the watcher wakes an idle firstmate.
  That is #86's script.
- The pull-request paths, scouts, steering and restart are not driven here.
