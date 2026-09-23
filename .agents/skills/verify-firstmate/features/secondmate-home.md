# Second mate home

A second mate is a persistent helper with its own isolated home and a charter.
Provisioning one must produce a home that really works: it knows who it is and who owns it, it carries its charter, firstmate can route work to it, and its agent can reach the skills it needs.
A home that looks complete and has no skills is the failure this covers.

## Sub-features

- `mate-provision` provisions a home from a charter and a routing scope.
- `mate-identity` gives the home its identity marker and the record of which home owns it.
- `mate-charter` copies the charter into the home.
- `mate-routing` registers the mate in the owning home's routing table, and the table validates.
- `mate-skills` leaves the harness skill link as a real link into a skills directory that is not empty.

## How to get to it (user POV)

- The captain asks for a persistent second mate for a domain, and firstmate runs `bin/fm-home-seed.sh <id> <home> <project>...` or `bin/fm-home-seed.sh <id> <home> --no-projects`.
- Firstmate passes `-` as the home to have a fresh worktree leased for the mate instead of naming a directory.
- Firstmate checks the routing table with `bin/fm-home-seed.sh validate`.
- A second mate on another machine is provisioned through the remote path, which this feature does not drive.

## Driving it with verify.sh

Preconditions:

- The doctor reports `# doctor: worth driving`.
- The checkout under test is a git repository the script can clone from, because a second mate home is a clone of firstmate itself.

- **Drive the feature.** Run `.agents/skills/verify-firstmate/verify.sh run secondmate-home`.
  The run ends with `verification: 1 passed, 0 failed, 0 skipped`.
- **Provision.** Inside the throwaway home, the script runs `bin/fm-home-seed.sh docsmate <mate directory> --no-projects` with `FM_SECONDMATE_CHARTER='Own the docs domain.'` and `FM_SECONDMATE_SCOPE='docs'`.
  It succeeds.
- **Read the identity.** The mate directory holds `.fm-secondmate-home`, and `.fm-secondmate-parent` carries a `parent_home=` line.
- **Read the charter.** `data/charter.md` in the mate directory is not empty.
- **Read the routing table.** `data/secondmates.md` in the throwaway home carries a line starting `- docsmate - `.
- **Read the skills.** `.claude/skills` in the mate directory is a symbolic link, resolves to a directory, and that directory is not empty.
- **Validate.** The script runs `bin/fm-home-seed.sh validate`.
  It succeeds.
- **Proof.** Read `secondmate-home/transcript.txt` in the evidence directory: one `ok` line per claim above and no `FAIL` line.

## Gotchas

- The seed clones with `core.symlinks=true`.
  A platform that cannot make the link fails the clone and rolls the home back, instead of leaving `.claude/skills` as a text file.
- The mate home is cloned from the commit under test, so uncommitted changes to tracked files are not in the mate.
  Commit a provisioning change before treating this feature as proof of it.
- The leased-worktree entry point, `-` as the home, and the remote path are not driven here.
  Do not report them as verified on the strength of this script.
- This proves provisioning only.
  Launching the mate's agent, handing it work, and retiring it start a real worker and are not part of this feature.
