# STATE.md — open work (handoff between sessions)

Updated 2026-11-28. Claude: update this at the end of any session where a
branch or PR changed state, then commit and push (see `CLAUDE.md`). Delete
entries that are done; git history keeps them.

## Branches on my fork

| Branch | State | Next step |
| --- | --- | --- |
| `woodpeckerOptimization-pr` | **merged** as PR #560 (2026-11-27, merge `8af1eacc`), incl. the maintainer's fixes `c073d86c`, `c233809c` | local branch is 2 behind origin: nothing to do, can be deleted |
| `woodpeckerOptimization` | superseded by #560 except `d3baea4` | see "Open items" |
| `feature/engine-speed-bench` | in progress; ahead 1 / behind 1 of origin | Engine Speed Lab plugin (`plugins/50_enginebench.tcl`, `docs/engine-speed-lab.md`, `tests/tcl/enginebench.tcl`): benchmark, Threads/Hash tuning by paired measurement (accept only > 1 % and > 2 SE). Reconcile local/origin; commits authored as "Claude": fix the author before a PR |
| `cb2Import` | in progress, on `upstream/github` `2aaec188`; 18 commits: 2CBH, import window, folder conversion and classic CBH done (2026-11-28, **not pushed: check `git status -sb`**) | see "ChessBase import" |
| `replay-training` (private repo) | in progress, last commit `66112d76` (Nov 18) | see "Repertoire Recall" |

## Open items

- **Swahili Difficulty labels** (`d3baea4`, only on
  `origin/woodpeckerOptimization`): Easiest = Easier and Harder = Hardest,
  so `tests/tcl/lichess_puzzles.tcl` fails. Own small PR; translations are
  the maintainer's, so say why (failing test, no lila Swahili to copy).
- Local `github` branch is behind upstream (still at `5c912dce`).

## ChessBase import (`cb2Import`)

- Done: notice (`docs/third-party-notices.md`, from oschess-cb-bridge
  v1.0.3 only: tag object b5c18be3 = commit bffebfc4), reader
  `src/cb2_*.{h,cpp}` + `src/codec_cb2.*`, hook `sc_base import x.2cbh`
  (`ICodecDatabase::CB2`, import only). gtest `test_codec_cb2.cpp` 30 tests
  (also clean under ASan+UBSan), `tests/tcl/cb2_import.tcl` 13 checks, in CI.
- Not read (no layout in v1.0.3): teams, sources. Games > 128 KB: moves only.
- Synthetic throughput in the cloud: 13.4 us/game (80 plies, cached).
- Phase 7 (`a889630f`): the import window (`importPgnFile`) offers
  `.2cbh` and sends it to `sc_base import` (no dup check: `import_nodup`
  is PGN-only); 3 en/it keys; harness now 15 checks. Phase 8 (`6c9c3385`):
  `Changelog.md` entry under `## Unreleased`.
- Local build: the toolchain globs `src/*.cpp`, nothing to add; built and
  passing on the home PC 2026-11-28.
- Import UX (`4936afbe`..`2b9847fd`): default filter PGN+ChessBase, menu
  label, `.cbh` reported as unreadable; Database > Convert a Folder to Scid
  Databases (`importFolderPlan`/`Run` in `tcl/tools/import.tcl`; partial
  bases deleted so a rerun resumes); it "Browse" = Sfoglia; changelog.
  `cb2_import.tcl` 22 checks. Dialog geometry checked in the GUI (it).
- Classic `.cbh` (`8433f526`..`b558f846`): `src/cbh_*` behind `CodecCB2`,
  ported from the same v1.0.3 (`cbh/`). `test_codec_cbh.cpp` 14 tests;
  CB2+CBH 44/44 with MinGW (a Windows-only test bug fixed on the way);
  `cb2_import.tcl` 22 checks, `startup_order` 32. Real data (129 small
  ChessBase databases on the home PC): 2297 records, 1722 games, 0 damaged,
  0 incomplete; all mode 0, 208 set-up starts. Modes 4/5/10 and `.cbj`
  over 4 GiB: fixtures only. Not read: guiding texts, sources, teams,
  header medals, annotation types other than text/symbols/squares/arrows
  (so no quotations, medals or evaluations from `.cbh`); the Chess960
  king/rook square bytes (outermost rook used).
- Real 2CBH test (2026-11-28): 45 databases from my OneDrive, converted
  from copies in `D:\...\Software\cb-import-test` (never convert inside
  OneDrive): 45/45 made, 7880 records, 7837 games, 9 too long (moves only).
  A large 2CBH database converted in ~4 min. **Found, not fixed yet**
  (verified with a temporary patch: 7855 games, 0 incomplete):
  (1) word `0xfffe` in the move tree is not a move: skip it, also in the
  look-ahead for the alternative marker (18 games were skipped);
  (2) annotation type `0x0a` = counted string (engine win/draw/loss as
  JSON) + 4 bytes (38 games lost later annotations). Unchecked: whether
  `0xfffe` takes an annotation position. The other 7 skipped games are
  pawn-only diagrams (tag `0x0a`, no kings): correct, message could say so.
- **Next**: fix (1) and (2); compare comment placement in a few `.cbh` games with ChessBase
  (positions are in stored order); a large `.cbh` (old Mega) for time;
  ASan+UBSan on `Test_CBH*` in the cloud; manual folder conversion on real
  files; push; run `scid.cmd ..\scidCommunity-notes\tools\cb2_counts.tcl
  <db>.2cbh` on Mega 2026/2027 and the updates (counts + time); cbtool
  oracle; PR + Discussion drafts in `pr-drafts/`. Default comment language
  is English; `CodecCB2::setLanguages()` exists but nothing in the UI sets it.

## Repertoire Recall (replay-training)

- Private repo `TBergh98/scidCommunity-private`, branch `replay-training`,
  not on the public fork. Read without a remote:
  `git fetch https://github.com/TBergh98/scidCommunity-private.git replay-training`
  then `git show FETCH_HEAD:PLAN.md` (Italian draft) and
  `docs/repertoire-recall.md`. Bugs found on the way go in
  `PR-DA-APRIRE.md` and become separate upstream PRs at the end.
- Goal: spaced repetition of the repertoire from the Tree masks, weighted by
  how likely each line is against the chosen Elo band.
- State: phases 5 (statistics) and 6 (adaptive chunks) done in the cloud,
  **to be tried locally**; open: ADR `docs/adr-reptrain.md`. 37 of the last
  40 commits authored as "Claude": fix before a PR.

## Next topics

- Engine optimisation experiments (Engine Speed Lab).
- Repertoire Recall.
- The low-RAM "fast tree" file (Discussion #479) was not merged; it stays
  an option if the normal Tree path is still too slow on 127k+-game
  positions.
