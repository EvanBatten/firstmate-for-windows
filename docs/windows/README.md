# firstmate on Windows

This branch is the Windows integration branch of the EvanBatten fork of [firstmate](https://github.com/kunchenguid/firstmate): upstream `main` plus the smallest set of patches that make the distro run under Git Bash with the herdr backend on native Windows 11, each meant to go back upstream.

- [plan.html](plan.html): the port plan, findings ledger, phases, and locked decisions (open it in a browser).
- [measurement.md](measurement.md): Phase A measurements against this machine, in the same shape as upstream's `windows-herdr-spike.yml` table.
- [prs.md](prs.md): the map from this branch's slice commits to the seven `pr-*` branches, with what each carries and what is held back.
- [upstream/](upstream/): what is written for the upstream maintainer - the covering [issue.md](upstream/issue.md) and the seven PR bodies [pr-1.md](upstream/pr-1.md), [pr-2.md](upstream/pr-2.md), [pr-3.md](upstream/pr-3.md), [pr-4.md](upstream/pr-4.md), [pr-5.md](upstream/pr-5.md), [pr-6.md](upstream/pr-6.md), [pr-7.md](upstream/pr-7.md). Written here, never sent from here.

Branches: `main` mirrors `upstream/main`; `windows` is this integration branch and the default; the seven `pr-*` branches each carry one upstream PR and are cut from `upstream/main`, except `pr-4` which is stacked on `pr-3` and `pr-7` which is stacked on `pr-2` (see [prs.md](prs.md)).
The live firstmate home is a clone of `windows` at `C:\Users\ebatt\firstmate`.
The pre-fork README commit is kept at tag `pre-fork-readme`.
