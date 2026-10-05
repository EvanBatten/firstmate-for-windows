# Install on Windows

[EvanBatten/firstmate-for-windows](https://github.com/EvanBatten/firstmate-for-windows) runs firstmate on Windows 11 under Git Bash, with Herdr as the runtime backend and Claude Code as the primary harness.
Clone this fork, not upstream, and take its default branch, `main`, because `main` carries the Windows overlay on current upstream while the older `windows` branch is frozen.

Before you clone, turn on Developer Mode in **Settings > System > For developers**.
Firstmate tracks symlinks, `.claude/skills` among them, and Windows lets an account create a symlink only with Developer Mode on or from an elevated shell.

```sh
gh auth login
git clone -c core.symlinks=true https://github.com/EvanBatten/firstmate-for-windows firstmate
cd firstmate
```

Git for Windows sets `core.symlinks=false` by default.
A clone without `-c core.symlinks=true` writes each tracked symlink as a small text file that holds the link target, so Claude Code finds no skills.

## Launch

Launch Claude Code through the Windows overlay in `platform/windows/`.
From PowerShell, add this line to your profile once, then run `claude` from the checkout:

```powershell
. C:\path\to\firstmate\platform\windows\claude.ps1
```

From Git Bash, source the overlay before you start Claude Code:

```sh
. platform/windows/env.sh && claude
```

Then continue with [Talk to it](../../README.md#talk-to-it) in the main README.

## Symlink repair

Each launch through the overlay repairs a clone made without `core.symlinks=true`.
It restores the tracked symlinks in the checkout and in every worktree of it, then turns `core.symlinks` on.
If a restore fails, for example because another git command holds the index lock, the launch leaves `core.symlinks` off and tries again next time.
It leaves a link path alone if you changed that file's content.
It does nothing in a copy that is not the top level of its own git repository, such as an unpacked archive.
If your account cannot create symlinks, the launch prints a message that tells you to turn on Developer Mode, and changes nothing.
To run the repair yourself, run `bash platform/windows/symlinks.sh .` from the checkout.
