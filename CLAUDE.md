# CLAUDE.md — personal notes for my fork `TBergh98/scidCommunity`

> **Never upstream.** These notes live only on the orphan branch `claude-notes`
> (worktree `../scidCommunity-notes`). In the main checkout `CLAUDE.md` is an
> untracked stub or symlink, excluded through `.git/info/exclude`. If
> `CLAUDE.md` or any notes file shows up in `git status`, a diff or a PR file
> list, **stop and tell me**.

`AGENTS.md` (the maintainer's) also applies: XERJ reference coding, always
pass `--prefix`. XERJ runs only on the maintainer's machine; if the `xerj` MCP
server fails here, work without it and say so.

## Other notes files — read them when the trigger applies

Paths are relative to the main checkout. Never `@`-import them: an import
loads them every session, which is what this split avoids.

| File | Read it when |
| --- | --- |
| `../scidCommunity-notes/STATE.md` | at the start of any session that continues earlier work, or when I ask what is open |
| `../scidCommunity-notes/MACHINES.md` | before building, running the app or running test harnesses |
| `../scidCommunity-notes/PR-CHECKLIST.md` | before opening a PR or pushing to a PR branch; before editing the areas it lists |
| `../scidCommunity-notes/SETUP.md` | setting up a new machine or a cloud session; if the notes look misconfigured |

Cloud sessions get the same layout from `cloud-setup.sh` (see `SETUP.md`).
If `../scidCommunity-notes` is missing there, read a file with
`git fetch origin claude-notes && git show FETCH_HEAD:<file>` and tell me.

## Keeping the notes up to date (Claude, mandatory)

- Any change to a notes file: commit and push it to `claude-notes` yourself,
  in the same turn, without asking. Commit from the notes worktree only:
  `git -C ../scidCommunity-notes add -A && git -C ../scidCommunity-notes commit -m "notes: <what>" && git -C ../scidCommunity-notes push`.
  Same command in the cloud (the worktree tracks `origin/claude-notes`).
- End of a session where a branch or PR changed state: update `STATE.md`
  (what is done, what is left, what is blocked), dated.
- A lesson goes into `PR-CHECKLIST.md` only when a mistake recurs or the
  maintainer fixes it in review, written as a specific, checkable rule.
- Keep this file under ~150 lines. No feature logs (git history has them),
  no codebase overview (read the code).

## Upstream and the maintainer

- Upstream `whelanh/scidCommunity`, maintainer Hugh Whelan (`whelanh`).
  PR target branch: **`github`** (not `main`/`master`). Remotes: `origin` =
  my fork, `upstream` = `whelanh/scidCommunity`.
- He often adapts my branches rather than merging them as they are, runs a
  bot review (CodeRabbit and others) plus his own, and pushes fixes onto the
  PR branch before merging: pull them before adding anything on top. Leave
  "Allow edits by maintainers" on.
- For performance problems he wants the existing path optimised before new
  files or formats: propose those in a Discussion first.
- He handles languages other than en/it and credits contributors in
  `README.md`/`Changelog.md` himself.
- **Communication**: Claude drafts PR descriptions, review replies and
  Discussion posts **in English**, in an uncommitted file (scratchpad, or
  `pr-drafts/`, excluded); **I** review and post them. Claude never posts on
  upstream unless I ask for that specific step.
- One feature per PR, made of atomic commits.

## Commits

- **Atomic**: one behaviour change per commit, building and passing tests on
  its own. Refactors, fixes found along the way and docs are separate commits.
- **Subject**: `area: what the program now does`, lowercase area, present
  tense, user's point of view, no trailing period. Areas so far: `woodpecker`,
  `docking`, `puzzles`, `install`, `docs`, `changelog`, `tests`, `Book window`,
  `OBR reader`, `Tools`, `Lichess Puzzles`, `scripts`.
  e.g. `docking: a saved layout restores its floating windows again`.
- **Body**: why (bug or need), how it was found, measured numbers when a
  choice depends on them, which tests cover it (file + number of checks).
  Wrap at ~72 columns.
- **Authorship**: I (`TBergh98`, my usual email) am the author of every
  commit; Claude is credited with `Co-Authored-By: Claude <model>
  <noreply@anthropic.com>`, also upstream.
  - Local and cloud: I am **both author and committer**. If `git var
    GIT_AUTHOR_IDENT` or `GIT_COMMITTER_IDENT` says `Claude`, stop and tell
    me before committing.
- Never commit secrets, Lichess tokens, local paths, or files from
  `~/Downloads/*` reference trees.

## Branches and PR flow

- One branch per feature on my fork. Parallel or throwaway work: a new
  branch named feature + purpose with `-`, not `/` (git refuses
  `feat/x` while `feat` exists), e.g. `woodpeckerOptimization-parallel-eval`;
  say which branch you used and how to merge it back.
- Cloud sessions get a `claude/<random>` branch: unless told otherwise in
  that session, ask whether to push to the feature branch instead.
- Before a PR: rebase on (or cherry-pick onto a fresh branch from)
  `upstream/github`, then walk through `PR-CHECKLIST.md`.
- No force-push on a branch the maintainer has pushed to.

## Tests

- New logic in a pure-Tcl module testable from `tclsh` (`woodpecker_core.tcl`
  pattern: no Tk, no `sc_*`, time passed in), harness in `tests/tcl/`
  **added to `.github/workflows/tcl-tests.yml`**. Code needing `sc_*`:
  `tests/<name>_app.tcl` run by the app. GUI: plugin-style test in the real
  app (`tests/woodpecker_gui.sh` pattern, prints each check as it runs).
- **Minimum before every push**: the touched area's `tests/tcl/*.tcl` +
  `tests/tcl/startup_order.tcl`. Commands per machine in `MACHINES.md`.
- CI also runs Tcl 9.0; no machine of mine has it.
- Known Windows-only harness failures, unrelated to my branches: tests
  needing UTF-8 source encoding, `file attributes -permissions` in
  `lichess_study_tk`, temp-path setup in three app harnesses. They fail on
  pristine upstream too: check there before blaming a branch.

## Translations

- Every new string: a `translate` key in `tcl/lang/english.tcl` and
  `tcl/lang/italian.tcl`, in the same commit as the string. Other languages
  are the maintainer's, unless the change replaces existing keys (then all
  catalogues, English text + TODO marker where there is no translation).
- Keep `\n`, `%s`/`%d`, brand names (Lichess) and command names (curl)
  literal. For Lichess-facing labels prefer Lichess's own (lila) wording.

## Licensing

- New files: `Copyright (C) 2026 Tommaso Bergamasco` +
  `SPDX-License-Identifier: GPL-2.0-or-later`.
- Imported code: check its licence first, record it in `COPYING` /
  `docs/third-party-notices.md`.

## Working with me

- Answer in Italian; code, commits, comments and docs in English.
- On Windows give me PowerShell commands (5.1: no `&&`; write files with
  `[IO.File]::WriteAllText` or `-Encoding ascii`/`utf8`, never `echo >>`).
- Measure before building on an assumption (feasibility probe before a
  feature; live, anonymous API checks for Lichess behaviour).
- **Autonomy**: atomic commits without asking on branches not in an open PR;
  push only when I ask (`claude-notes` excepted). Branch in an open PR: ask
  before committing.
- **Stop and ask** on design choices and on anything the maintainer might
  frown at: shared modules, behaviour changes outside the feature, new
  dependencies, style departures. Small UI tweaks: just do them.
- Models (I usually pick): Opus for design, review, pre-PR fixes; Sonnet for
  well-defined fixes and small UI changes.
