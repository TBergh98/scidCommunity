# MACHINES.md — build, run and test on each of my machines

Check `$env:COMPUTERNAME` and use the matching section. A new machine: ask me
for the paths and add a section. No machine has Tcl 9.0 or xvfb: CI covers
both.

## Home PC (`UBIK`, Windows 11)

- Checkout `D:\MyDocuments\SCACCHI\Software\scidCommunity-repo\scidCommunity`
  (+ `..\scidCommunity-notes`); its `CLAUDE.md` is the import stub.
- Compiler: **MinGW**, not MSVC: WinLibs GCC (UCRT) + cmake + ninja in the
  private toolchain `D:\MyDocuments\SCACCHI\Software\scid-toolchain\`
  (`mingw64\`). The repo's CMake supports only MSVC on Windows, so the
  toolchain has its own `CMakeLists.txt`. Tcl/Tk 8.6.15 copy inside it
  (`tcltk\` headers, `lib\`, `runtime\`).
- Build: `scid-toolchain\build.cmd` (incremental) →
  `<checkout>\build\scidCommunity.exe`. The exe loads `tcl\` of the checkout
  live: Tcl changes show on restart, rebuild only after `src\` changes;
  after adding/removing a `.cpp`, delete `scid-toolchain\build\` first.
  `run-branch.cmd` (checkout root, excluded) builds the branch and starts
  the GUI; close any open instance first.
- Run isolated: `scid-toolchain\scid.cmd [script.tcl]`, user folder
  redirected to `scid-toolchain\userdata\scidCommunity\` (never touches
  `%APPDATA%`). `scid.cmd script.tcl` runs `sc_*` without a GUI (`puts` →
  stdout, end with `exit 0`); `--headless` is JSON-RPC
  (`docs/HEADLESS_API_SPEC.md`).
- **No standalone `tclsh`.** Harnesses: `scid-toolchain\scid.cmd
  tests\tcl\<name>.tcl`; read the printed `failures` line (exit code not
  verified to reflect it). Source files need UTF-8 encoding for some
  harnesses.
- GUI checks: a `.tcl` in `userdata\scidCommunity\plugins\` runs at GUI
  start; `scid-toolchain\shot.ps1 -Out x.png -Title scid` captures the
  window. `wsl.exe` exists but no distro is set up.
- Installed copy (visual check): `C:\Program Files\scidCommunity\`, user
  folder `%APPDATA%\scidCommunity\`; repo Tcl can be tried there as a
  `NN_name.tcl` in `%APPDATA%\scidCommunity\plugins\` (`plugins/README.md`).
- Stockfish: `C:\Program Files\scidCommunity\engines\stockfish.exe`.

## Work PC (Windows 11)

- Checkout `C:\Users\bergamascot\Documents\Varie\scidCommunity-personal`
  (+ `..\scidCommunity-notes`).
- Compiler: VS Build Tools 2022, not on PATH: first
  `call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64`;
  CMake bundled in `Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin`.
- Tcl/Tk 8.6.15 built from source like CI (`release.yml`): sources
  `Documents\Varie\tcltk`, install `Documents\Varie\tcldir`. The PC sets
  `NoDefaultCurrentDirectoryInExePath=1`, so `nmake` cannot run its own
  `nmakehlp.exe`: `set NoDefaultCurrentDirectoryInExePath=` before `nmake`.
- Build in `build\`: `cmake -DTCL_INCLUDE_PATH=...\tcldir\include
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DWITH_MD_LIBRARY=OFF ..` then
  `cmake --build . --config Release --target INSTALL` →
  `build\install\bin\scidCommunity.exe`.
- Harnesses: `tclsh` from Anaconda 8.6 on PATH, or
  `tcldir\bin\tclsh86t.exe`.
- Stockfish:
  `C:\Users\bergamascot\Documents\Varie\stockfish\stockfish\stockfish-windows-x86-64-universal.exe`.

## Linux (CI, or any Linux box)

- `mkdir build && cd build && cmake -DCMAKE_BUILD_TYPE=Release .. && make -j$(nproc)`
- `tclsh tests/tcl/<name>.tcl`; `build/scidCommunity tests/<name>_app.tcl`;
  `xvfb-run -a tests/woodpecker_gui.sh build/scidCommunity`.
- CI startup smoke needs `SCIDCOMMUNITY_VERSION` set (shallow checkouts
  have no tags).
