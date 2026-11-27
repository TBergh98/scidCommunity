# PR-CHECKLIST.md — walk through before every PR

Each rule comes from a bug the maintainer (or his review bots) fixed, or a
mistake that recurred. Add a rule only on the same terms (see `CLAUDE.md`).

## Process

- [ ] Rebased on `upstream/github`; `Changelog.md` re-checked (a cherry-pick
      once re-added an old entry and moved mine into a released section).
- [ ] `git diff upstream/github --stat`: only the feature (no notes files,
      scratch scripts, local config).
- [ ] New harness added to `.github/workflows/tcl-tests.yml`.
- [ ] en + it translations in the same commit as each string.
- [ ] Docs and code comments don't point at renamed files.
- [ ] No local paths, tokens, or `Co-Authored-By` missing; author is me.

## Failure paths (most review findings are here)

- [ ] Every `error`/`catch` path resets the module state (a leftover `run`
      flag left the evaluator "busy" forever).
- [ ] A partial result (engine died, download cancelled) never overwrites
      good data with blanks.
- [ ] Error paths close what they opened (half-built bases hold DB slots).
- [ ] Closing a progress window with the WM close button = Cancel
      (`wm protocol ... WM_DELETE_WINDOW`).
- [ ] Caches remember the parameters they were fetched with.
- [ ] "Do it all" actions don't replace data that shipped with the set.
- [ ] Replacing a file: rename, and put the old one back if the rename
      fails (sync clients and antivirus hold files); never `-force` over a
      leftover temp file from an earlier crash (`c073d86c`).
- [ ] A dialog that holds a plan built from some data closes when that data
      is replaced (session start, reset, restore) (`c073d86c`, `c233809c`).
- [ ] ID counters include retired/deleted IDs, so a new item never inherits
      an old one's state (`c073d86c`).

## Security and files

- [ ] Secret files created 0600 **at open time** (exclusive create), never
      chmod afterwards; temp file removed on failure (flagged twice).
- [ ] Atomic writes: temp file + rename, no partial outputs.

## Global state in Tcl

- [ ] Package-wide settings (`::http::config -useragent`) swapped and
      restored, also on error.
- [ ] `<Destroy>` bound on a toplevel fires for its children too: check `%W`.
- [ ] `sc_game push/pop` (one slot per base), engine ids in `::reviewdriver`
      (20–28 are taken by Woodpecker parallel grading), DB slots: shared,
      assume another window uses them.
- [ ] `::docking::layout_restore` rebuilds `.main` and lets Tk idle half-way:
      run queued `after idle` work (`update idletasks`) first.

## Tcl 8.6 vs 9.0

- [ ] Don't compare formatted values whose spelling changed
      (`file attributes -permissions`: `00600` in 8.6, `0o600` in 9.0 →
      compare `[format %o ...]`).

## Upstream coupling

- [ ] A feature reusing another module's labels/API (Game Review verdicts →
      Woodpecker marks) has a test that fails when those labels change;
      when upstream touches the review, re-run the marks tests.
- [ ] `sc_game pgn` localises piece letters in non-English UIs: use
      `-english` for anything sent outside (Lichess).

## External APIs (Lichess)

- [ ] Documented behaviour verified live and anonymously; responses
      validated anyway (side to move from `initialPly`, difficulty).
- [ ] One request at a time, User-Agent on every transport, back off on 429.
- [ ] Anonymous `/api/puzzle/batch` repeats the same 50 puzzles for ~1 min
      per angle+difficulty; only `easiest/easier/normal/harder/hardest`
      exist, anything else is silently served as `normal`.
