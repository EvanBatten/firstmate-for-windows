# firstmate on Windows

This branch is the Windows integration branch of the EvanBatten fork of [firstmate](https://github.com/kunchenguid/firstmate): upstream `main` plus the smallest set of patches that make the distro run under Git Bash with the herdr backend on native Windows 11, each meant to go back upstream.

- [plan.html](plan.html): the port plan, findings ledger, phases, and locked decisions (open it in a browser).
- [measurement.md](measurement.md): Phase A measurements against this machine, in the same shape as upstream's `windows-herdr-spike.yml` table.

Branches: `main` mirrors `upstream/main`; `windows` is this integration branch and the default; `pr-*` branches will carry one upstream PR each.
The live firstmate home is a clone of `windows` at `C:\Users\ebatt\firstmate`.
The pre-fork README commit is kept at tag `pre-fork-readme`.
