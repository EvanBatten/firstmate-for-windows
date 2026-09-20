# Verification suite

One script per feature, each answering a single question: does this feature work on **this** installation?

```sh
tests/verification/run.sh                 # all of them
tests/verification/run.sh secondmate-home # just one
```

## What these are, and what they are not

A script in `tests/` pins a contract with fakes and must pass on any machine.
A script here runs the real `bin/` scripts against a real throwaway home and reports what actually happened.
They exist because a green portable lane does not tell you the tool works on the machine in front of you: two of the defects they cover shipped green lanes and a clean worktree while the feature was silently broken.

Run them by hand before trusting an installation, after a platform change, and when something feels wrong and you want to know which feature is at fault.

## The contract each script keeps

- **One feature.** The filename names it, and every line of output is a claim about that feature in plain language.
- **Its own home.** Each builds a throwaway home under the system temp directory and removes it on exit, so nothing touches an operating home and order never matters.
- **No shared state.** A failure in one says nothing about the others.
- **Honest exit.** `0` all passed, `77` this machine cannot answer the question, anything else is a real failure.
- **A failure says what is wrong, not which assertion tripped.** "the harness skill link is a plain file holding ../.agents/skills, so this mate has no skills" beats "expected symlink".

## Current coverage

| Script | Feature |
| --- | --- |
| `captain-inbox` | A note captured mid-turn reaches firstmate once, and stops counting as waiting after it is handled |
| `wake-queue` | Work is delivered, survives until acknowledged with the generation it was handed, and leaves nothing behind |
| `captain-decision` | A question for the captain is carried by a real work item until his own words close it |
| `condition-watch` | "Do X as soon as Y is true" fires its action and tells firstmate |
| `steer-guard` | An instruction is never delivered to a worker in the wrong home |
| `local-only-landing` | Approved local work lands by fast-forward, and a diverged branch is refused |
| `secondmate-home` | A provisioned second mate home has its identity, charter, routing entry, and working skills |

Two of these carry a regression that already bit us: `wake-queue` covers the temp files a drain used to abandon (#59), and `secondmate-home` covers the skills a mate used to be silently provisioned without (#60).

## Adding one

Copy the shape of an existing script: source `lib.sh`, call `verify_home`, use `ok` and `bad`, end with `verify_done`.
Call `verify_skip` when the machine genuinely cannot answer, which is not a failure.
Do not reach for `verify_home` inside a command substitution; it sets globals, and a subshell would drop them.
