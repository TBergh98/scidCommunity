# Engine Speed Lab

`plugins/50_enginebench.tcl` measures how fast a UCI engine runs on this
machine and searches for the option values that make it fastest. It is one
Tcl file with no dependencies, usable in two ways that share the same code:

- **Plugin.** Copy the file into the plugins folder (see
  [`plugins/README.md`](../plugins/README.md)) and restart scidCommunity:
  **Tools → Engine Speed Lab...**
- **Command line.** `tclsh plugins/50_enginebench.tcl --engine <path>`.
  This is the way to script it or run it on a machine without scidCommunity.

It starts the engine itself and speaks plain UCI to it, so the numbers
describe the engine binary and not a GUI.

## Benchmark

```
tclsh plugins/50_enginebench.tcl --engine C:\engines\stockfish.exe --option Threads=8 --option Hash=1024
```

Without `--engine` it uses `$ENGINEBENCH_ENGINE`, then `stockfish` on the
`PATH`. In the plugin the engine is a preset from the engine list (its stored
options are used) or any executable chosen with **Browse...**.

Every test starts a fresh engine process, sends `ucinewgame` before each
position, and records what the engine reports in its last `info` line plus the
wall-clock time from `go` to `bestmove`.

| Test | What is fixed | What it tells you |
| --- | --- | --- |
| `movetime` | time per position | nodes/second and the depth reached: the numbers a GUI shows |
| `depth` | search depth | time to depth |
| `nodes` | node count | time for the same work; repeatable with one thread |
| `scaling` | time, for a range of `Threads` | nodes/second speed-up and efficiency per thread |
| `bench` | Stockfish's own `bench` command | a figure comparable with published Stockfish benches (Stockfish only) |

Profiles choose a set of tests: `quick` (movetime 2 s on 4 positions),
`standard` (movetime 5 s and depth 20 on 16 positions, the default) and `full`
(all five). `--tests`, `--movetime`, `--depth`, `--nodes` and `--positions`
override them; `--positions` also takes an EPD or FEN file.

The 16 built-in positions are taken from Stockfish's `bench` set and cover the
opening, middlegame and endgame, because nodes/second differs several-fold
between them (pawn endings run two to three times faster than middlegames).

### Reports

Each run writes three files with the same content to `--out`
(`./enginebench-reports`; in the plugin, `enginebench` inside the user
folder): `.md`, `.html` and `.json`. `Hashfull` is in per mille, as the engine
reports it.

### Comparing with ChessBase

The report of a `movetime` test ends with a **ChessBase comparison sheet**:
four positions (start, a tactical middlegame, a quiet middlegame, an endgame)
with their FEN, the depth reached and the kN/s measured here. In ChessBase:

1. load the *same engine executable* with the *same* `Threads` and `Hash`;
2. one line only (MultiPV 1), no second engine, no tablebases unless the
   benchmark had them;
3. paste the FEN, start the analysis, and read kN/s and depth after the same
   number of seconds.

The HTML report has a field next to each position: type the ChessBase kN/s
and it shows the difference in percent. A GUI displays the `nps` the engine
itself sends, so the two figures measure the same thing; what can differ is
what the GUI does to the process (priority, affinity, options it sets on its
own). Differences of a few percent are noise.

## Tuning

```
tclsh plugins/50_enginebench.tcl --engine <path> --tune
```

or **Tune engine** in the plugin, then **Save tuned preset**, which stores the
result as a new engine preset (`<name> (tuned)`) and leaves the original alone.

The tuner is a measurement loop, not a model:

1. The baseline is the engine's defaults plus any `--option` given.
2. For each tunable option, every candidate value is measured on the same
   positions (`--repeats` times each, default 2) in a fresh engine process.
3. A candidate replaces the current best only if its gain, paired position by
   position, is above 1% **and** above two standard errors. Otherwise the
   current value stays, so noise cannot move the result.
4. With several options the pass is repeated once, since they can interact.

**Objective.** `nps` (default) maximises nodes per second at a fixed time per
position. `ttd` minimises the time to a fixed depth; it is the more direct
measure of search progress but noisy with more than one thread, because a
multi-threaded search does not visit the same tree twice. Use more
`--repeats` with it.

**What is searched.** By default `Threads`, over 1, half the cores, the
physical cores, the logical cores and the values in between (on macOS also
the number of performance cores). `--param NAME=A,B,C` searches any other
option the engine offers, e.g. `--param NumaPolicy=auto,system,none`.

**Hash** is not chosen by speed, because a larger table barely changes
nodes/second while a too small one costs playing strength. The tuner picks the
smallest size (16, 64, 256, ... MB, up to half the RAM) whose average
`hashfull` stays at or below 300‰ after `--target-time` milliseconds of search
(default 10 s), following Stockfish's measurement that strength drops once
the average hashfull passes about 30%. If you analyse for minutes rather than
seconds, raise `--target-time` accordingly. `--hash-rule sweep` treats Hash
like any other option instead; `--hash-rule off` leaves it alone.

### Limits

- Nodes per second is not playing strength. With Lazy SMP, doubling the nodes
  per second by adding threads gains less than doubling the time would;
  Stockfish measures about 82% efficiency from 1 to 8 threads at long time
  controls. Only games (thousands of them, e.g. with cutechess) measure
  strength, and this tool does not play games.
- The acceptance rule uses a handful of positions; it is a guard against
  noise, not a formal significance test.
- `MultiPV`, `Skill Level`, `UCI_LimitStrength` and similar options change what
  the engine computes, not how fast it runs. Do not tune them for speed.

## What affects engine speed, by operating system

The report's **System checks** section tests the points below where it can.

| Factor | Windows | macOS | Linux |
| --- | --- | --- | --- |
| Binary | Use the build for your CPU (`avx2`, `bmi2`, `avx512`, ...). A generic build can be much slower. | Apple Silicon needs the native ARM build; an x86 build under Rosetta is slower. | As Windows. |
| Threads | Logical processors, minus 1–2 if the machine is in use. SMT helps. | As Windows; threads on efficiency cores are slower, so the performance-core count is tried. | As Windows. |
| Hybrid CPUs | Windows can place the engine on efficiency cores. Priority "Above normal" or an affinity limited to performance cores avoids it. | Scheduling is automatic. | Usually handled by the kernel; `taskset` pins if needed. |
| Large pages | Off unless the account has **Lock pages in memory** (`secpol.msc`), then sign out or reboot. Typically 5–10% nodes/second, more with a large hash. Checked. | Not supported by Stockfish. | Through transparent huge pages, normally already on. Checked. |
| Power | High-performance plan, mains power. The active plan is reported. | Low Power Mode off. | `performance` governor avoids ramp-up noise. Reported. |
| NUMA / >64 threads | Stockfish 17 and later handle processor groups and NUMA themselves (`NumaPolicy`). | — | `NumaPolicy`, as on Windows. |

Sources: the Stockfish documentation —
[FAQ: optimal settings, slow engine](https://official-stockfish.github.io/docs/stockfish-wiki/Stockfish-FAQ.html),
[Advanced topics: large pages, measuring speed](https://official-stockfish.github.io/docs/stockfish-wiki/Advanced-topics.html),
[Useful data: hash, threading efficiency, MultiPV](https://official-stockfish.github.io/docs/stockfish-wiki/Useful-data.html).
The `NumaPolicy` row and the Rosetta remark are not covered by those pages
and have not been measured here.

## Tests

`tclsh tests/tcl/enginebench.tcl` runs the driver, benchmark, tuner and report
writers against a scripted UCI engine with known answers.
