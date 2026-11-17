# Plugins

scidCommunity loads every `*.tcl` file in its `plugins` folder, in name
order, when it starts (after scidCommunity's own Tcl files and before any
database is opened). If the folder does not exist, nothing is loaded and
scidCommunity starts as usual.

The folder lives inside your scidCommunity user folder:

| Platform | Location |
| --- | --- |
| Linux | `~/.scidX.Y/plugins` (`X.Y` is the version, e.g. `5.1`) |
| macOS | `~/Library/Application Support/scidCommunity/plugins` |
| Windows | `%APPDATA%\scidCommunity\plugins` |

Plugins are ordinary Tcl. They run with full access, exactly like
scidCommunity's own code, so they can define and wrap procs, add menus, or
bind keys. Files are loaded in alphabetical order (prefix names with a
number when order matters, e.g. `10_mine.tcl`). A plugin that fails to load
is reported and skipped, and scidCommunity keeps starting normally.

## ⚠️ Security

**Plugins are executable code.** They run with the full privileges of your
user account and are not sandboxed, signed, or verified, so a malicious
plugin can do anything you can — read, modify or delete your files, use the
network, or run other programs.

Only install plugins you trust. Do not drop `*.tcl` files into this folder
from sources you do not trust, and if you did not write the plugin yourself,
be sure you know where it came from.

There is no stable plugin API; a plugin that wraps scidCommunity's own procs
may need updating when those procs change.

## Bundled plugins

| File | What it does |
| --- | --- |
| `50_enginebench.tcl` | **Engine Speed Lab**: benchmarks a UCI engine over a set of positions, writes a report (with a sheet for comparing against ChessBase), and tunes `Threads`, `Hash` and other options by measurement. Also runs from the command line. See [`docs/engine-speed-lab.md`](../docs/engine-speed-lab.md). |

Bundled plugins are not loaded automatically: copy the file into the
plugins folder described above to enable it.
