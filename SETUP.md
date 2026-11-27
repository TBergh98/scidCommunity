# SETUP.md — how the notes are wired on each machine

All notes files live only on the orphan branch `claude-notes` (no shared
history with `github`, so it can never be merged or offered as a PR). Only
`CLAUDE.md` is linked into the main checkout; the other files are read by
path from the worktree.

## New machine (bash; main checkout at `~/scidCommunity`)

```bash
cd ~/scidCommunity
git fetch origin claude-notes
git worktree add ../scidCommunity-notes claude-notes
ln -s ../scidCommunity-notes/CLAUDE.md CLAUDE.md
echo '/CLAUDE.md' >> .git/info/exclude
```

## New machine (Windows PowerShell 5.1)

One command per line (`echo >>` writes UTF-16, which git cannot read):

```powershell
git fetch origin claude-notes
git worktree add ..\scidCommunity-notes claude-notes
Add-Content -Path .git\info\exclude -Value '/CLAUDE.md' -Encoding ascii
New-Item -ItemType SymbolicLink -Path CLAUDE.md -Target ..\scidCommunity-notes\CLAUDE.md
```

The symlink needs Developer Mode or an admin shell. Without it, use an
import stub (the home PC does this):
`[IO.File]::WriteAllText("$PWD\CLAUDE.md", "@../scidCommunity-notes/CLAUDE.md`n")`.
The stub must import only `CLAUDE.md`, never the other notes files.

## Optional: pull the notes after every checkout/pull

Git hooks are never committed, so they stay on that machine:

```bash
for h in post-checkout post-merge; do
  printf '#!/bin/sh\ngit -C ../scidCommunity-notes pull -q --ff-only 2>/dev/null || true\n' > .git/hooks/$h
  chmod +x .git/hooks/$h
done
```

On Windows write hook files with `[IO.File]::WriteAllText` (LF, no BOM).

## Cloud sessions

- The environment's setup script copies the latest `claude-notes:CLAUDE.md`
  into the checkout (excluded) and sets my identity (author me, committer
  Claude, see `CLAUDE.md`). It copies **only** `CLAUDE.md`: read the other
  files with `git fetch origin claude-notes && git show FETCH_HEAD:<file>`.
- To edit: `git fetch origin claude-notes`, worktree on `FETCH_HEAD`,
  commit, `git push origin HEAD:claude-notes`.

## If upstream adds its own tracked `CLAUDE.md`

The symlink/stub will clash on checkout: move it to `CLAUDE.local.md` (or
another excluded file) containing `@../scidCommunity-notes/CLAUDE.md`.

## Why no `.claude/rules/`, skills or hooks for these notes

Path-scoped rules, skills and project hooks live in the main repo's
`.claude/`, which upstream tracks (`.claude/skills/xerj`). Notes must never
enter the main repo, so the "read X when Y" table in `CLAUDE.md` replaces
them.
