# CLAUDE.md — personal working notes (fork `TBergh98/scidCommunity`)

> **Never upstream.** This file lives only on the orphan branch `claude-notes`
> of my fork. Feature/PR branches never contain it: in the main checkout it is a
> symlink ignored through `.git/info/exclude` (local-only, not `.gitignore`).
> If you (Claude) see `CLAUDE.md` in `git status`, in a diff or in a PR file
> list, **stop and tell me** — something is misconfigured.
>
> Placeholders look like `<!-- TODO(Qn): ... -->`: they are still to be filled
> (by me, or by Claude through the questionnaire with the same `Qn` number).

**Session start protocol (Claude):**
1. If this is a **local** session and any `TODO(Q…)` is still in this file,
   ask me those questions first (one `AskUserQuestion` round), fill the
   answers in, and commit them to `claude-notes` (§0). Q5 (my local build and
   test setup) is the priority.
2. Make sure commits will be authored by me, not by "Claude" (§1.2).
3. Read §4 (lessons) before touching code in an area listed there.

`AGENTS.md` (checked in by the maintainer) also applies: XERJ reference coding,
always pass `--prefix`. XERJ runs only on the maintainer's machine; if the
`xerj` MCP server fails to start here, work without it and say so.

---

## 0. How this file is managed

One-time setup on a new machine (main checkout at `~/scidCommunity`):

```bash
cd ~/scidCommunity
git fetch origin claude-notes
git worktree add ../scidCommunity-notes claude-notes
ln -s ../scidCommunity-notes/CLAUDE.md CLAUDE.md
echo '/CLAUDE.md' >> .git/info/exclude
```

On **Windows PowerShell 5.1** (my work PC, checkout
`C:\Users\bergamascot\Documents\Varie\scidCommunity-personal`): no `&&`, no
`ln`, and `echo >>` writes UTF-16, which git cannot read. Run one per line:

```powershell
git fetch origin claude-notes
git worktree add ..\scidCommunity-notes claude-notes
Add-Content -Path .git\info\exclude -Value '/CLAUDE.md' -Encoding ascii
New-Item -ItemType SymbolicLink -Path CLAUDE.md -Target ..\scidCommunity-notes\CLAUDE.md
```

The symlink needs Developer Mode or an admin shell. Without it, use an import
stub instead: `[IO.File]::WriteAllText("$PWD\CLAUDE.md", "@../scidCommunity-notes/CLAUDE.md`n")`
(then edit the real file in `..\scidCommunity-notes`). Write hook files with
`[IO.File]::WriteAllText` too (LF line endings, no BOM). Claude: on Windows,
give me PowerShell commands, not bash.

**Auto-sync (Claude, mandatory):** every time you change this file, commit and
push it to `claude-notes` yourself, in the same turn, without asking me. Never
leave notes edits uncommitted or unpushed, so every machine stays up to date.
Commit only this file, from the notes worktree (never the main checkout).

Editing: edit `CLAUDE.md` as usual (it is the symlink, or the stub pointing at
the worktree), then commit from the notes worktree:

```bash
git -C ../scidCommunity-notes commit -am "notes: <what changed>" && git -C ../scidCommunity-notes push
```

Optional local auto-sync — git hooks in `.git/hooks/` are never committed, so
they stay on this machine. They pull the notes after every checkout and pull:

```bash
for h in post-checkout post-merge; do
  printf '#!/bin/sh\ngit -C ../scidCommunity-notes pull -q --ff-only 2>/dev/null || true\n' > .git/hooks/$h
  chmod +x .git/hooks/$h
done
```

**One copy, seen everywhere.** The only copy is on `claude-notes`; nothing goes
on `github` or on feature branches (it would show up in PRs):
- locally, every feature branch sees the same file, because the symlink is
  untracked and a checkout never touches it; the hooks above fetch edits made
  elsewhere (e.g. in a cloud session);
- in cloud sessions the environment's setup script copies the latest
  `claude-notes:CLAUDE.md` into the checkout (excluded) when the container is
  built; mid-session, re-read it with
  `git fetch origin claude-notes && git show FETCH_HEAD:CLAUDE.md`;
- Claude may commit and push edits of this file to `claude-notes` from any
  session (local or cloud) — this is my standing permission for that branch
  only. In a cloud session: `git fetch origin claude-notes`, then commit the
  change on a worktree of `FETCH_HEAD` and `git push origin HEAD:claude-notes`.

- The `claude-notes` branch shares no history with `github`: it can never be
  merged or cherry-picked into a PR by accident, and GitHub never offers it
  as a PR to `whelanh/scidCommunity`.
- If upstream ever adds its own tracked `CLAUDE.md`, the symlink will clash on
  checkout: then move the link to `CLAUDE.local.md` or import this file from
  upstream's with `@../scidCommunity-notes/CLAUDE.md` in a local, excluded file.

---

## 1. General rules (mine — they override defaults)

### 1.1 Upstream and the maintainer

- Upstream: `whelanh/scidCommunity`, maintainer Hugh Whelan (`whelanh`).
  Default/PR target branch: **`github`** (not `main`/`master`).
- What the history shows about how he works (Nov 2026):
  - He often **adapts** my branches rather than merging them as they are:
    `obr-book-support` went in through his `dev/obr-book` (PR #473),
    `tree-stats-progress-cancel` was re-done in his `3e5032dc` with a
    `Co-Authored-By` for me, the Lichess study feature was my design shipped
    in his PR #456.
  - He runs a **review pass** (CodeRabbit + his own) and pushes fixes himself
    before merging (`16c8e22`, `6dd59ff` on `woodpecker-pr`, PR #529). Every
    one of those fixes is a lesson below — read §4 before opening a PR.
  - He handles the **other languages** himself ("Add translations" commits,
    machine translation); I ship English + Italian.
  - He credits contributors in `README.md` and `Changelog.md` himself.
- **Communication**: Claude drafts PR descriptions, replies to reviews and
  Discussion posts **in English**, in an uncommitted file I can open (the session
  scratchpad, or `pr-drafts/` excluded via `.git/info/exclude`); **I**
  review and post them.
  Claude never posts on upstream (PRs, issues, Discussions, reviews).
- **PR size**: one feature per PR, made of atomic commits (as #529). Leave
  "Allow edits by maintainers" on: he pushes his review fixes onto the PR
  branch, so pull them before adding anything on top.

### 1.2 Commits

- **Atomic**: one behaviour change per commit, building and passing the
  tests on its own. Refactors, fixes found along the way (e.g. `b329b3c`
  docking fix found by the Woodpecker GUI test) and docs are separate commits.
- **Subject**: `area: what the program now does`, lowercase area, present
  tense, describing behaviour from the user's side, no trailing period.
  Areas used so far: `woodpecker`, `docking`, `puzzles`, `install`, `docs`,
  `changelog`, `tests`/`test`, `Book window`, `OBR reader`, `Tools`,
  `Lichess Puzzles`, `scripts`.
  - Good: `woodpecker: create the Lichess token file 0600 from the start`
  - Good: `docking: a saved layout restores its floating windows again`
- **Body**: why (the bug or the need), how it was found, measured numbers
  when a choice depends on them (e.g. "depth 12 gives the same labels as
  depth 18 at a twelfth of the cost"), and which tests cover it (file + count
  of checks). Wrap at ~72 columns.
- **Authorship**: I am the author of every commit (`TBergh98`, my usual
  commit email); Claude is **always** credited with a
  `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer, also
  upstream. Cloud containers default to `Claude <noreply@anthropic.com>` as
  author (11 Woodpecker commits of Nov 17 were authored that way): the cloud
  environment's setup script sets my identity; if `git config user.name`
  still says `Claude`, stop and tell me before committing.
- **Cloud sessions: author me, committer Claude** (decided 2026-11-24).
  Cloud git signs every commit with Anthropic's SSH key, and GitHub marks a
  signed commit "Verified" only when the key belongs to the committer's
  email: my email as committer gave "Unverified". So in the cloud checkout:
  `git config author.name TBergh98`, `git config author.email <my email>`,
  `git config committer.name Claude`, `git config committer.email
  noreply@anthropic.com`. GitHub then shows "TBergh98 authored and Claude
  committed", Verified, and the commit counts as mine. Locally (my own
  unsigned commits) nothing changes.
- Never commit secrets, Lichess tokens, local paths, or files from
  `~/Downloads/*` reference trees.

### 1.3 Branches and PR flow

- **One branch per feature on my fork** (`TBergh98/scidCommunity`), e.g.
  `feature/engine-speed-bench`, `woodpeckerOptimization`, `obr-book-support`.
  Claude pushes directly to the feature branch it is working on (my branch,
  never upstream's).
- **Parallel or risky work** (two sessions on one feature, an experiment that
  may be thrown away): Claude may open a new branch named after the feature
  **and** the purpose of that session, e.g.
  `woodpeckerOptimization-parallel-eval`, `engine-speed-bench-hash-tuning`.
  Use `-`, not `/`: git refuses `woodpeckerOptimization/x` while a branch
  `woodpeckerOptimization` exists. Say which branch you used and how it
  should be merged back.
- Cloud sessions get a `claude/<random>` branch from the harness: unless I
  said otherwise in that session, ask whether to push to the feature branch
  instead.
- Before opening a PR: `git fetch upstream && git rebase upstream/github`
  (or cherry-pick onto a fresh branch from it), then re-check
  `Changelog.md`: a cherry-pick once re-added an old CQL entry and moved mine
  into a released section (`34fa521`).
- `git diff upstream/github --stat` before pushing the PR branch: nothing
  outside the feature (no `CLAUDE.md`, no scratch scripts, no local config).
- No force-push on a branch the maintainer has pushed to.

### 1.4 Tests before a PR

- New logic goes in a pure-Tcl module testable from `tclsh`
  (`woodpecker_core.tcl` pattern: no Tk, no `sc_*`, time passed in), with a
  harness in `tests/tcl/` **added to `.github/workflows/tcl-tests.yml`**.
- Code needing `sc_*`: `scidCommunity tests/<name>_app.tcl`.
- GUI: a plugin-style test driven in the real app under `xvfb-run`
  (`tests/woodpecker_gui.sh` pattern, clean `$HOME`, prints each check as it
  runs so a hang shows where it stopped).
- CI also runs a **Tcl 9.0** job: anything touching file attributes,
  integer formatting, `CONST84`/list APIs must be checked against 9.0.
- **My machines.** Check `$env:COMPUTERNAME` and use the matching row. If no
  row matches (a new machine), ask me for the paths and add the row.
  Remotes everywhere: `origin` = my fork, `upstream` = `whelanh/scidCommunity`.

  | | Work PC (Windows 11) | Home PC (`UBIK`, Windows 11) |
  | --- | --- | --- |
  | Checkout | `C:\Users\bergamascot\Documents\Varie\scidCommunity-personal` (+ `..\scidCommunity-notes`) | `D:\MyDocuments\SCACCHI\Software\scidCommunity-repo\scidCommunity` (+ `..\scidCommunity-notes`, the `claude-notes` worktree). Its `CLAUDE.md` is the import stub, not a symlink |
  | Compiler | VS Build Tools 2022 (`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`), not on PATH: `call "...\VC\Auxiliary\Build\vcvarsall.bat" x64` first; CMake bundled in `Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin` | **MinGW**, not MSVC: WinLibs GCC 16.2 (UCRT) + cmake + ninja in the private toolchain `D:\MyDocuments\SCACCHI\Software\scid-toolchain\` (`mingw64\`; also on PATH via winget). The repo's own CMake supports only MSVC on Windows, so the toolchain has its own `CMakeLists.txt` |
  | Tcl/Tk for the build | 8.6.15 built from source like CI (`release.yml`): sources `Documents\Varie\tcltk`, install `Documents\Varie\tcldir` (no admin needed). The work PC sets `NoDefaultCurrentDirectoryInExePath=1`, so `nmake` cannot run its own `nmakehlp.exe` → `set NoDefaultCurrentDirectoryInExePath=` in the cmd before `nmake` | 8.6.15 copy inside the toolchain: headers `tcltk\`, import libs `lib\`, DLLs and Tcl/Tk libraries `runtime\` (does not use `C:\Program Files`) |
  | Build | `build\` in the checkout, `cmake -DTCL_INCLUDE_PATH=...\tcldir\include -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DWITH_MD_LIBRARY=OFF ..` then `cmake --build . --config Release --target INSTALL` → `build\install\bin\scidCommunity.exe` (first built 2026-11-23, Tcl+Tk+scid in a few minutes; `build\` is git-ignored) | `scid-toolchain\build.cmd` (incremental) → `<checkout>\build\scidCommunity.exe`. The exe loads **`tcl\` of the checkout live**: Tcl changes show on restart, rebuild only after `src\` changes; after adding/removing a `.cpp`, delete `scid-toolchain\build\` first. `run-branch.cmd` in the checkout root (git-excluded) builds the current branch and starts the GUI — close any open instance first |
  | Run isolated | — | `scid-toolchain\scid.cmd [script.tcl]`: own Tcl/Tk, user folder redirected to `scid-toolchain\userdata\scidCommunity\` (never touches `%APPDATA%`). `scid.cmd script.tcl` runs `sc_*` commands without a GUI (`puts` → stdout, end with `exit 0`); `scid.cmd --headless` is the JSON-RPC mode (`docs/HEADLESS_API_SPEC.md`); a `.tcl` in `userdata\scidCommunity\plugins\` runs at GUI start and `scid-toolchain\shot.ps1 -Out x.png -Title scid` captures the window |
  | Installed copy (visual check) | — | scidCommunity 5.1.1 in `C:\Program Files\scidCommunity\` (Tcl in `share\scid\tcl\`), user folder `%APPDATA%\scidCommunity\`. To try repo Tcl there without a build, drop a `NN_name.tcl` in `%APPDATA%\scidCommunity\plugins\` (see `plugins/README.md`); `src\` changes never reach it |
  | `tclsh` for harnesses | Anaconda 8.6 on PATH (`anaconda3\Library\bin\tclsh.exe`); the built `tcldir\bin\tclsh86t.exe` also works. No local Tcl 9.0 → CI covers it | **No `tclsh` on this PC.** Run the harnesses with the built exe: `scid-toolchain\scid.cmd tests\tcl\<name>.tcl` (checked 2026-11-24 on `startup_order.tcl`: 32 checks, 0 failures). Read the printed `failures` line, I have not checked that the exit code reflects it. No local Tcl 9.0 → CI covers it |
  | xvfb / GUI tests | none (Windows) → GUI tests in CI or WSL | none; `wsl.exe` exists but I have not set up a distro for this. Drive the GUI with a plugin + `shot.ps1` (above) or leave it to CI |
  | Stockfish | `C:\Users\bergamascot\Documents\Varie\stockfish\stockfish\stockfish-windows-x86-64-universal.exe` | `C:\Program Files\scidCommunity\engines\stockfish.exe` (ships with the installed app; no copy under `D:\...\Software`) |

  Home PC details also live in `LOCAL_DEV.md` (checkout root, git-excluded,
  that PC only). If the two disagree, fix whichever is stale and say so.

- **Minimum before every push**: the `tests/tcl/*.tcl` harnesses of the
  touched area + `tests/tcl/startup_order.tcl`; app/GUI/Tcl 9.0 are left to CI.

### 1.5 Translations

- Every new string: a `translate` key in `tcl/lang/english.tcl` and
  `tcl/lang/italian.tcl`. Other languages: leave them to the maintainer
  unless the change replaces existing keys (then update all catalogues, with
  the English text and the TODO marker where no translation exists, as in
  `40f603f`).
- Keep `\n`, `%s`/`%d`, brand names (Lichess) and command names (curl)
  literal — machine translation mangled them once (`df5c639c`, `a609357c`).
- For Lichess-facing labels prefer Lichess's own translations (lila).

### 1.6 Licensing

- New files: `Copyright (C) 2026 Tommaso Bergamasco` +
  `SPDX-License-Identifier: GPL-2.0-or-later`.
- Imported code: check its licence first and record it in `COPYING` /
  `docs/third-party-notices.md` (`ctg2obr.cpp` is GPL-3.0-or-later because
  of jja's move table — `102418ec`).

### 1.7 Working with Claude

- Answer me in Italian; code, commits, comments and docs in English.
- Ask before large design choices; for small UI tweaks just do them.
- Measure before building on an assumption (the Woodpecker feasibility probe
  `ed4cf44` before the trainer; live API checks for Lichess behaviour).
- **Models** (I usually pick the model myself; these are the defaults):
  Opus for design, review and pre-PR fixes; Sonnet for well-defined bug
  fixes and small UI changes; Sonnet with an Opus advisor for well-defined
  tasks that need reading a lot of context.
- **Autonomy**:
  - Make atomic commits as you go, without asking, on branches that are not
    in an open PR.
  - My personal/private branches: commit freely, **push only when I ask**
    (`claude-notes` is the exception: commit and push, §0).
  - A branch in an **open PR** (others see or build on it): ask before
    committing.
- **Stop and ask** on design choices, and before any change the maintainer
  might frown at (touching shared modules, behaviour changes outside the
  feature, new dependencies, style departures).

---

## 2. Project quick reference

| What | Where / how |
| --- | --- |
| Tcl UI | `tcl/` (`tcl/tools/*.tcl` features, `tcl/windows/`, `tcl/lang/`) |
| C++ engine / `sc_*` commands | `src/` (`src/polyglot/` books) |
| Start-up source order | `tcl/start.tcl` (checked by `tests/tcl/startup_order.tcl`) |
| Menus | `tcl/menus.tcl` |
| Build (CMake) | `mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j$(nproc)` |
| Build (configure) | `./configure && make` |
| Pure-Tcl tests | `tclsh tests/tcl/<name>.tcl` |
| App tests | `build/scidCommunity tests/woodpecker_app.tcl` |
| GUI tests | `xvfb-run -a tests/woodpecker_gui.sh build/scidCommunity` |
| CI | `.github/workflows/tcl-tests.yml` (jobs: tclsh harnesses, Tk dialogs, startup smoke, Tcl 9.0) |
| Design docs | `docs/` (`woodpecker-method.md`, `obr_format.md`, …) |

---

## 3. Feature log

### 3.1 OpenBook Rich (.obr) reader + Book window — Nov 10–12, upstream via PR #473

- `src/polyglot/obrbook.{h,cpp}`; `polyglot_open()` detects `.obr` by magic;
  `sc_book obrmoves`; Book window columns, W/D/B bar, ChessBase colours,
  sortable headers. Spec: `docs/obr_format.md`.
- Problems → solutions:
  - Truncated/empty file stayed "open" and fell through to the Polyglot
    parser → validate header tables against file size, fill the slot only
    after every check (`75b9716f`).
  - `<Destroy>` on a toplevel also fires for children: redrawn canvases
    closed every book, and the next `sc_book positions` on a closed slot made
    polyglot call `exit()` → react only when `%W` is the window (`92a083e3`).
  - Fast double-click on a sort header selected text in the panel →
    maintainer disabled selection bindings (`1ea1af3b`).
  - Hard-coded English columns → maintainer added translation keys
    (`c2b2277b`). Lesson: translate from the first commit.

### 3.2 CTG → OBR converter — Nov 12, upstream via PR #473

- `tools/ctg2obr.cpp` from openbook-rich (commit `999879f`), `main()` →
  `ctg2obr()`, `sc_book ctg2obr`, Tools menu, progress + cancel.
- Writes to `.part` and renames at the end: no partial book on failure/cancel.
- `configure` builds with exceptions off → `ctg2obr.o` gets `-fexceptions`
  and catches everything internally.
- Output verified byte-identical to the reference on a 2.3 GB book (~4 min).
- Licence: GPL-3.0-or-later (jja), recorded in `COPYING`.

### 3.3 Publish to Lichess study — upstream via PR #456 (maintainer's PR, my design)

- `tcl/tools/lichess_study.tcl`, token with `study:read/study:write`.
- Fixes applied upstream: token file 0600, `vwait` guarded against a dialog
  destroyed while `update` drained events, translations' `\n` restored
  (`df5c639c`); `sc_game pgn` localises piece letters in non-English UIs and
  Lichess rejected them → new `-english` option (`ce3190b7`).
- I implemented the whole feature; the maintainer merged it (with the fixes
  above). Nothing open.

### 3.4 Tree stats progress bar + cancel — upstream as `3e5032dc` (PR #484)

- My Tcl-side work from `tree-stats-progress-cancel`, adapted by the
  maintainer: `progressBarSet` scale + `progressBarContinue`, tree search
  fills 30 %, stats the rest; cancel on a changed position marks the tree
  stale and reschedules.
- Origin: my Discussion #479 proposed a precomputed "fast tree" file
  (`<base>.tree`, 438 MB for 13M games, ~3 min build) because the Tree
  window froze on huge bases. The maintainer preferred fixing the normal
  path first: start position answered from the index
  (`IndexEntry::GetStartFlag()` instead of the serial loop in
  `SearchPos::setFilterStdStart`, 20 s cold search gone), multi-threaded
  `scidBaseT::getTreeStat`, sequential I/O instead of `MADV_RANDOM`
  (`src/filemap.h`), tree cache bounded in MB, timings exposed to Tcl. He
  merged the C++ plumbing himself (`eab694d`) and took only my Tcl/UI
  progress+cancel part (PR #484, released in 5.1.4.67). The fast-tree file
  was not merged; it stays an option for low-RAM users (depth 2–4 stats on
  127k+-game positions need it).
- Lesson: for performance problems he wants the existing path optimised
  before adding new files/formats — propose in a Discussion first.

### 3.5 Lichess Puzzles difficulties — `40f603f`

- Only `easiest/easier/normal/harder/hardest` exist; unknown values are
  served as `normal` silently. Old saved values migrated on load.
- `color` on `/api/puzzle/batch` works for nb>1 in practice, but each
  puzzle's side is still checked from `initialPly` (even = Black to move).
- User-Agent on all three transports (curl `-A`, `http` `-useragent`
  swapped for the request, PowerShell `-UserAgent`).
- Test against a fake Lichess: `tests/tcl/lichess_puzzles.tcl`.

### 3.6 Woodpecker Method trainer — Nov 17–21, PR #529 (`woodpecker-pr`)

- Modules: `tcl/tools/woodpecker_{core,set,eval,ui}.tcl`; data under
  `<user dir>/woodpecker` (or a chosen synced folder); bundled puzzles
  `puzzles/set-1..9-*.pgn` + `puzzles/marks.tsv`; design in
  `docs/woodpecker-method.md`; tools in `scripts/woodpecker/`,
  `scripts/build_puzzle_sets.py`.
- Key decisions: pure core with time passed in; marks from the Game Review's
  verdicts at depth 12 (calibrated on 150 puzzles); one attempt per exercise
  (was two, changed to match Lichess, `4b238cf`); bundled puzzles default,
  Lichess opt-in; inverse-density weighting per 50 rating points;
  token never in a synced folder.
- Problems → solutions:
  - `sc_game push/pop` has one slot per base shared with other windows: the
    open game was lost → sessions play in a MEMORY base of their own.
  - `::docking::layout_restore` dropped every floating window (compared the
    whole `{Toplevel .w}` pair) → compare the first word (`b329b3c`).
  - Clicking a Text widget steals focus from `.` arrow bindings → hand focus
    back to the board on any click in the panel (`c4aaa99`).
  - Game Review changes upstream relabelled moves (`great`, then
    `brilliant`) and `markFor` silently lost `!`/`!!` (`33da54e`, `d11d2ff`)
    → when upstream touches the review, re-run the marks tests.
  - Anonymous `/api/puzzle/batch` returns the same 50 puzzles for ~1 min per
    angle+difficulty → rotate angles, wait 20 s when a round brings nothing.
  - Without a token Lichess serves a 1500 player → emulate lila's
    `PuzzleDifficulty`/`PuzzlePath` bands from the user's rating.
  - Adding rating bands must not change published sets → one seeded RNG per
    set (`5a7b5dc`).
- Fixed by the maintainer in review (`16c8e22`, `6dd59ff`) — see §4.

### 3.7 Repertoire Recall (Replay-training) — Nov 2026, private → not yet

- **Where**: private repo `TBergh98/scidCommunity-private`, branch
  `replay-training` (not on the public fork). Read it without a remote:
  `git fetch https://github.com/TBergh98/scidCommunity-private.git replay-training`
  then `git show FETCH_HEAD:PLAN.md`. The design is `PLAN.md` (Italian,
  still a draft) + `docs/repertoire-recall.md`; bugs found along the way go
  in `PR-DA-APRIRE.md` and become separate upstream PRs at the end (phase 7).
- **Goal**: spaced repetition of the repertoire read from the Tree masks,
  weighted by how likely each line is against opponents of the chosen Elo
  band, without sessions blowing up on large repertoires.
- **Files**: `tcl/tools/reptrain_{core,db,ui}.tcl` (core is pure Tcl, run by
  `tclsh` and by the simulations), `tests/tcl/reptrain_{core,db}.tcl`,
  `tests/reptrain_db_app.tcl`, `tests/reptrain_gui.{sh,tcl}`,
  `scripts/reptrain/` (sim, plots, DB diagnosis). Planned C++:
  `scidBaseT::getMaskStats` + `sc_tree maskstats` (one pass over the
  base for all mask positions, per-50-Elo histograms, cached).
- **Key decisions**: item = (my-turn position, repertoire move); one shared
  state keyed by position+move (survives mask/database/Elo changes);
  priority = Σ need × (1 − R) / minutes, Gumbel-top-k sampling; time budget
  with ±1 min; active repertoire = 95% of probability mass; 25% new quota;
  memory `R = 0.9^(days/S)` with 3 outcomes; chunks by per-boundary
  Beta-Bernoulli hesitation (HMM rejected: too little data); Elo kernel
  left Gaussian σ 133 cut at −400, right exponential H 200 (to confirm on
  plots); online and blitz/rapid games excluded by default; data as TSV
  under `<user dir>/reptrain/`, state rebuildable from the append-only log.
- **State (Nov 18)**: phases 5 (statistics) and 6 (adaptive chunks) done in
  the cloud, **to be tried locally**; last work was on malleable clusters
  and slow answers. Open: ADR `docs/adr-reptrain.md` (TODO in `PLAN.md`).

---

## 4. Lessons learned (checklist before every PR)

**Failure paths** (the maintainer's review found most bugs here)
- [ ] On every `error`/`catch` path, is the module state reset? (`eval::start`
      left `run` set → "busy" forever.)
- [ ] A partial result (engine died, download cancelled) must not overwrite
      good data with blanks.
- [ ] Error paths close what they opened (half-built bases hold DB slots).
- [ ] Closing a progress window with the WM close button = Cancel
      (`wm protocol ... WM_DELETE_WINDOW`).
- [ ] Leftovers/caches remember the parameters they were fetched with.
- [ ] Destructive "do it all" actions must not replace data that shipped
      with the set (evaluate only what has no marks).

**Security / files**
- [ ] Secret files created 0600 **at open time** (exclusive create), never
      chmod after; temporary file removed on failure. (Flagged twice:
      Lichess study, then Woodpecker `6f4fc99`.)
- [ ] Atomic writes: temp file + rename; no partial outputs.

**Global state in Tcl**
- [ ] Never leave package-wide settings changed (`::http::config
      -useragent`): swap and restore, also on error (`5ee3f93`).
- [ ] `<Destroy>` bindings on toplevels: check `%W`.
- [ ] `sc_game push/pop`, engine ids in `::reviewdriver`, DB slots are
      shared resources: assume another window uses them.
- [ ] `::docking::layout_restore` rebuilds `.main` and lets Tk idle
      half-way: run queued `after idle` work (`update idletasks`) before
      it, or it hits a board without its toolbar (`41c16bc`).

**Tcl 8.6 vs 9.0**
- [ ] Don't compare formatted values whose spelling changed: e.g.
      `file attributes -permissions` is `00600` in 8.6, `0o600` in 9.0 →
      compare `[format %o ...]` (`6dd59ff`).

**Upstream coupling**
- [ ] Features reusing another module's labels/API (Game Review verdicts)
      need a test that fails when those labels change.
- [ ] After rebasing/cherry-picking: check `Changelog.md`, docs references
      to renamed files (the ADR → `woodpecker-method.md` rename left stale
      pointers in code comments, fixed by the maintainer).

**External APIs (Lichess)**
- [ ] Verify documented behaviour live (anonymously) before relying on it;
      validate the response anyway (side to move, difficulty).
- [ ] One request at a time, User-Agent, back off on 429.

**Process**
- [ ] Translations for en + it in the same commit as the string.
- [ ] New harness added to the CI workflow.
- [ ] `git diff upstream/github --stat` contains only the feature.

---

## 5. Template — new feature entry

```markdown
### 3.N <Feature name> — <dates>, <branch> → <PR link or "not yet">

- Goal: <one sentence, user's point of view>
- Files: <modules, tests, docs>
- Key decisions: <choice — reason / measurement>
- Problems → solutions:
  - <symptom> → <root cause> → <fix> (`<commit>`)
- Maintainer review: <what he changed and why>
- Open items: <…>
```

---

## 6. Current work and open items

Branches on my fork (as of 2026-11-24):

| Branch | State | Notes |
| --- | --- | --- |
| `woodpeckerOptimization` | in progress, **two features + two fixes mixed: split before any PR** (see "Before the Woodpecker PRs" below) | `dfc063bd` grades a set on several engines at once (ids 21–28, 1 thread, Hash 64; 160 puzzles: 69 s → 31 s on 4 engines). Marks differ from a serial run on 4–11 % of puzzles (per-engine hash); `tests/woodpecker_eval_parallel.tcl` fails above 20 %. Touches `review_driver.tcl` (shared with Game Review → keep its tests green). Then (Nov 23–24, cloud): inner circle, reset/restore statistics, daily load in the new-set dialog (`51e3cb3`..`438a3f3`, then `7886457`, `3152582`, `e99c32e`, `19a6387`; all pushed Nov 24), design in `docs/woodpecker-method.md` Decisions 8–9. |
| `feature/engine-speed-bench` | in progress | `f6433796` Engine Speed Lab plugin (`plugins/50_enginebench.tcl`, `docs/engine-speed-lab.md`, `tests/tcl/enginebench.tcl`): benchmark, Threads/Hash tuning by paired measurement (accept only > 1 % and > 2 SE). Authored as "Claude" — fix the author before a PR (§1.2). |
| `woodpecker-pr` | merged | PR #529, upstream `4638d7e`. |
| `replay-training` (private repo) | in progress | Repertoire Recall, §3.7. Last commit `66112d76` (Nov 18). 37 of the last 40 commits authored as "Claude" — fix before a PR (§1.2). |

### Before the Woodpecker PRs (from `woodpeckerOptimization`)

Claude: when a PR from this branch comes up, walk through this list first.

1. **Split into separate PRs**, each cherry-picked onto a fresh branch from
   `upstream/github` (§1.3):
   - *parallel evaluation*: `dfc063b` alone;
   - *inner circle + reset + daily load*: `51e3cb3`, `9fa357e`, `d05c2e2`,
     `2181821`, `ff19585`, `925eee8`, `438a3f3`, `3152582`, `e99c32e`;
   - *fix, the next move while the reply animates* (`7886457` dragged
     moves, `19a6387` click moves: the reply waited 200 ms with the opponent
     to move, so a piece grabbed then did not lift and the move was lost; bug
     in #529 code, found by me Nov 24): its own small PR, like `41c16bc`.
     **Tell the maintainer in that PR**: for players who move by clicks it
     is a visible change: in a Woodpecker session their own move no longer
     slides, it lands at once when the reply starts (`::board::update`
     cancels the running animation); only the reply slides. Chosen to keep
     the fix inside the trainer, without touching `pressSquare`/board code;
     the alternative (a premove hook in `main.tcl`) would keep both
     animations but touch shared code;
   - *fix, leaving a session mid-exercise* (`41c16bc`, bug in #529 code,
     found Nov 23): its own small PR, or the first commit of the feature PR
     with a clear "fix" in the description;
   - *fix, Swahili Difficulty labels* (`d3baea4`: Easiest = Easier and
     Harder = Hardest, `tests/tcl/lichess_puzzles.tcl` was failing): its
     own PR. Translations are the maintainer's, so say why (a failing test,
     no lila Swahili to copy).
2. **Squash the follow-ups** into the commits they change, and reword:
   `ff19585` (opening mid-circle) and `3152582` (order) → `9fa357e`;
   `925eee8` (shorter texts, first-cycle load only) and `e99c32e` (grey
   help lines) → `51e3cb3` + `9fa357e` + `d05c2e2`; `438a3f3` → `2181821`. Keep the cloud identity (§1.2) when rewriting.
3. Inner circle semantics to keep (my decisions, Nov 23–24): the circle is a
   prefix of the cycle's order; opened exercises always come **after** the
   circle, in the running cycle and in every later one (Nov 24: opened-first
   was confusing); each dialog choice has a short label plus a grey help line
   (Nov 24: too terse was as bad as too verbose); reset archives the log as
   `ring-<date>.tsv`, Restore offers only the newest ring; the daily load
   shows the first cycle only.
4. **Backward compatibility, checked Nov 25** (say it in the PR): the
   release's Woodpecker (`4638d7e`) created sets and played a real session
   in a clean HOME, then the branch's code opened the same folder: dayPlan,
   progress, session/cycle statistics, mark status and the sets list were
   identical (173 values), sessions continued, no Tk errors; the release's
   own `tests/tcl/woodpecker_core.tcl` (164 checks) passes against the new
   core. Nothing to migrate: no option or file format changed; the new
   data (log `C` rows, set.tsv `retired`, `ring-*.tsv`) is optional. The
   other way (a synced folder opened by the old release) loses nothing but
   ignores the circle and shows moved/given-back exercises again. Re-run
   this check (old worktree + same binary) if the branch changes again.
5. The usual §4 checklist, Changelog check, `git diff upstream/github
   --stat`.

Next topics:
- Woodpecker follow-ups (after #529).
- Engine optimisation experiments (Engine Speed Lab, parallel evaluation).
- Replay-training ("Repertoire Recall", §3.7).
