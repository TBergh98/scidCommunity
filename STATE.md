# STATE.md — open work (handoff between sessions)

Updated 2026-11-27. Claude: update this at the end of any session where a
branch or PR changed state, then commit and push (see `CLAUDE.md`). Delete
entries that are done; git history keeps them.

## Branches on my fork

| Branch | State | Next step |
| --- | --- | --- |
| `woodpeckerOptimization-pr` | **merged** as PR #560 (2026-11-27, merge `8af1eacc`), incl. the maintainer's fixes `c073d86c`, `c233809c` | local branch is 2 behind origin: nothing to do, can be deleted |
| `woodpeckerOptimization` | superseded by #560 except `d3baea4` | see "Open items" |
| `feature/engine-speed-bench` | in progress; ahead 1 / behind 1 of origin | Engine Speed Lab plugin (`plugins/50_enginebench.tcl`, `docs/engine-speed-lab.md`, `tests/tcl/enginebench.tcl`): benchmark, Threads/Hash tuning by paired measurement (accept only > 1 % and > 2 SE). Reconcile local/origin; commits authored as "Claude": fix the author before a PR |
| `replay-training` (private repo) | in progress, last commit `66112d76` (Nov 18) | see "Repertoire Recall" |

## Open items

- **Swahili Difficulty labels** (`d3baea4`, only on
  `origin/woodpeckerOptimization`): Easiest = Easier and Harder = Hardest,
  so `tests/tcl/lichess_puzzles.tcl` fails. Own small PR; translations are
  the maintainer's, so say why (failing test, no lila Swahili to copy).
- Local `github` branch is behind upstream (still at `5c912dce`).

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
