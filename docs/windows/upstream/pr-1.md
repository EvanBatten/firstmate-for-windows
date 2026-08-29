# PR-1: check every file out with LF so the scripts run under Git Bash

Branch: `EvanBatten:pr-1-gitattributes` -> `kunchenguid/firstmate:main`.
One file, five lines, four of them a comment.

## What is wrong today

The repository has no `.gitattributes`.
Git for Windows sets `core.autocrlf=true` in both its system and global config, which is the installer default that almost every Windows contributor has.
So a plain `git clone` on Windows checks out every `bin/*.sh` with CRLF line endings, and a shebang line that ends `#!/usr/bin/env bash\r` does not name an interpreter that exists:

```console
$ grep -l $'\r' bin/*.sh | wc -l
151
$ bin/fm-harness.sh
bash: bin/fm-harness.sh: cannot execute: required file not found
```

151 of 151 scripts, before a single line of firstmate runs.
Nothing else in the port can be measured until this is fixed, which is why it is the first PR.

This is not only about contributors' checkouts.
`.github/workflows/windows-herdr-spike.yml` sources `bin/fm-backend.sh` on `windows-latest`, and `actions/checkout` there runs with the same Git for Windows defaults.
The spike works today because sourcing a CRLF file tolerates more than executing one does, but any step in that workflow that executes a script rather than sourcing it hits the same wall.

## The fix

```gitattributes
# Every text file is committed and checked out with LF so the bash
# scripts run under Git Bash on Windows, where core.autocrlf=true is the
# Git for Windows default and would otherwise rewrite each shebang to
# "bash".
* text=auto eol=lf
```

`text=auto` lets Git decide which files are text; `eol=lf` pins the working-tree ending for those files on every platform.
Binary files are unaffected because `text=auto` does not classify them as text.

The whole-tree rule is safe for this repository in particular: there are zero `.bat`, `.cmd`, `.ps1` and `.sln` files in it, which are the file types that genuinely want CRLF preserved.
If any are added later, they get their own `eol=crlf` line beneath this one.

## What this changes for existing clones

Nothing in the repository's committed content: everything is already LF in the object database, so `git diff` is empty after this lands.
A Windows clone made *before* this PR keeps its CRLF working tree until it is refreshed (`git rm --cached -r . && git reset --hard`), which is the normal `.gitattributes` adoption step and is worth a line in the release notes.
macOS and Linux checkouts are byte-identical before and after; on those platforms `core.autocrlf` is `false` by default and nothing was being rewritten in the first place.

## Verification

Measured on Windows 11, Git Bash 5.2 (MINGW64), `uname -s` = `MINGW64_NT-10.0-26200`, `git 2.x` with the stock Git for Windows config.

| Check | Before | After |
| --- | --- | --- |
| `grep -lc $'\r' bin/*.sh \| wc -l` on a fresh clone | 151 | 0 |
| `bin/fm-harness.sh` | `cannot execute: required file not found` | runs |
| `git diff` on an existing LF checkout | - | empty |

The rest of this port's four PRs were all developed and measured on a checkout with this file in place.

## One thing this PR cannot fix, which belongs in the same paragraph of the setup docs

A `.gitattributes` cannot express symlink policy, and there is a second checkout-time git setting that breaks a Windows clone just as completely.

Git for Windows ships `core.symlinks=false` in its **system** config.
This repository tracks exactly one symlink - `.claude/skills -> ../.agents/skills`, git mode 120000 - and that is how Claude Code is shown firstmate's twenty skills.
Under the installer default it is checked out as a 17-byte regular file holding the target path, so the skills directory does not exist as far as the harness is concerned:

```console
$ ls -la .claude/skills
-rw-r--r-- 1 ebatt 197609 17 Aug 29 03:20 .claude/skills
$ cat .claude/skills
../.agents/skills
```

A whole session ran that way here before it was noticed; `/bearings` answers `Unknown command: /bearings` and nothing else says anything is wrong.
The repair needs no admin step on a machine with Developer Mode on, and the running session picked the skills up without a restart:

```console
$ git config core.symlinks true && rm -f .claude/skills && git checkout -- .claude/skills
$ ls -la .claude/skills
lrwxrwxrwx 1 ebatt 197609 17 Aug 29 19:38 .claude/skills -> ../.agents/skills/
#   next /bearings: "20 skills available"
```

So the Windows setup line is `git clone -c core.symlinks=true`, and it wants to sit next to whatever this PR's `.gitattributes` note ends up saying.

## Notes for the reviewer

This is deliberately a whole-repository rule rather than a `*.sh` rule.
A mixed policy is the thing that actually bites later: a `.json` or `.md` that a script reads with `read -r` behaves differently under CRLF, and Git for Windows' patched `grep`, `sed` and `awk` silently strip a trailing CR before matching, so a CRLF file can be wrong in a way no text tool will show you.
Pinning the whole tree removes the class of problem rather than the instance.
