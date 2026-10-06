# Install on Windows

[EvanBatten/firstmate-for-windows](https://github.com/EvanBatten/firstmate-for-windows) runs firstmate on Windows 11 under Git Bash, with Herdr as the runtime backend and Claude Code as the primary harness.
Clone this fork, not upstream, and take its default branch, `main`, because `main` carries the Windows overlay on current upstream while the older `windows` branch is frozen.

## Turn on Developer Mode

Turn on Developer Mode in **Settings > System > For developers** before you clone.
Firstmate tracks symlinks, `.claude/skills` among them, and Windows lets an account create a symlink only with Developer Mode on or from an elevated shell.

## Install the tools

Install these tools from PowerShell before you clone.
Firstmate cannot start without them, and its own install hints do not cover Windows.

1. Install Git for Windows, which also installs Git Bash.

   ```powershell
   winget install --id Git.Git -e
   ```

2. Install the GitHub CLI.

   ```powershell
   winget install --id GitHub.cli -e
   ```

3. Install Node.js.
   The overlay runs `node` to lay out Herdr panes, and firstmate installs its helper tools with `npm`.

   ```powershell
   winget install --id OpenJS.NodeJS.LTS -e
   ```

4. Install jq.

   ```powershell
   winget install --id jqlang.jq -e
   ```

5. Install Claude Code, then run `claude` once and sign in.

   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```

6. Install Herdr.

   ```powershell
   irm https://herdr.dev/install.ps1 | iex
   ```

7. Install Treehouse 2.0.1, the version CI pins.
   Its install script stops on Windows, so download the release and put `treehouse.exe` in `%USERPROFILE%\.local\bin`, the folder that holds `claude.exe`.

   ```powershell
   gh release download v2.0.1 -R kunchenguid/treehouse -p "*windows-amd64.zip" -D $env:TEMP
   Expand-Archive "$env:TEMP\treehouse-v2.0.1-windows-amd64.zip" "$env:USERPROFILE\.local\bin" -Force
   ```

Open a new PowerShell window so that it picks up the new `PATH`.
On its first start, firstmate lists any other tool it is missing and asks before it installs one.

## Clone

```sh
gh auth login
git clone -c core.symlinks=true https://github.com/EvanBatten/firstmate-for-windows firstmate
cd firstmate
```

Git for Windows sets `core.symlinks=false` by default.
A clone without `-c core.symlinks=true` writes each tracked symlink as a small text file that holds the link target, so Claude Code finds no skills.

## Launch

Firstmate on Windows runs its workers in Herdr, and it picks Herdr automatically when Claude Code starts inside a Herdr pane.
Claude Code must also start through the Windows overlay in `platform/windows/`.

1. Start Herdr from PowerShell.

   ```powershell
   herdr
   ```

2. In the Herdr pane, add the overlay's `claude` function to the profile of that pane's PowerShell, then load it.
   Herdr can start a different PowerShell than your terminal does, and each one reads its own `$PROFILE`, so run these lines in the Herdr pane.
   Replace `C:\path\to\firstmate` with the folder you cloned into.

   ```powershell
   if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
   Add-Content $PROFILE '. C:\path\to\firstmate\platform\windows\claude.ps1'
   . $PROFILE
   ```

3. Go to the clone and start Claude Code.
   The function applies the overlay only when the current folder is the top folder of the clone.

   ```powershell
   cd C:\path\to\firstmate
   claude
   ```

You add the profile line once.
After that, every launch is steps 1 and 3.

If the Herdr pane runs Git Bash instead of PowerShell, source the overlay before you start Claude Code.

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
