#!/usr/bin/env tclsh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Engine Speed Lab -- benchmark and tune the speed of a UCI chess engine.
#
# One file, two ways to use it:
#
#   * scidCommunity plugin: copy it into <user folder>/plugins (see
#     plugins/README.md). It adds "Tools -> Engine Speed Lab...".
#   * command line:  tclsh 50_enginebench.tcl --engine /path/to/stockfish
#     (run with --help for the options).
#
# Both drive the same library (namespace ::enginebench), which talks plain UCI
# to the engine, so it measures the engine binary itself and not a GUI.
# Documentation: docs/engine-speed-lab.md

namespace eval ::enginebench {
    variable version 0.1
    variable cancel 0
    variable logCmd ""
    variable Q
    variable Sig
    variable Eof
    variable Last
    array set Q {}
    array set Sig {}
    array set Eof {}
    array set Last {}

    # Built-in positions: {name phase chessbase-sheet fen}. The FENs are the
    # ones Stockfish's own `bench` uses, spread over the phases of the game
    # because nodes/second differs a lot between them.
    variable positions {
        {start       opening    1 {rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1}}
        {kiwipete    middlegame 1 {r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 10}}
        {mg-attack   middlegame 0 {4rrk1/pp1n3p/3q2pQ/2p1pb2/2PP4/2P3N1/P2B2PP/4RRK1 b - - 7 19}}
        {mg-open     middlegame 0 {r3r1k1/2p2ppp/p1p1bn2/8/1q2P3/2NPQN2/PPP3PP/R4RK1 b - - 2 15}}
        {mg-kside    middlegame 1 {r1bq1rk1/ppp1nppp/4n3/3p3Q/3P4/1BP1B3/PP1N2PP/R4RK1 w - - 1 16}}
        {mg-knights  middlegame 0 {2rqkb1r/ppp2p2/2npb1p1/1N1Nn2p/2P1PP2/8/PP2B1PP/R1BQK2R b KQ - 0 11}}
        {mg-bishops  middlegame 0 {3r1rk1/p5pp/bpp1pp2/8/q1PP1P2/b3P3/P2NQRPP/1R2B1K1 b - - 6 22}}
        {mg-castled  middlegame 0 {r1q2rk1/2p1bppp/2Pp4/p6b/Q1PNp3/4B3/PP1R1PPP/2K4R w - - 2 18}}
        {mg-closed   middlegame 0 {r3k2r/3nnpbp/q2pp1p1/p7/Pp1PPPP1/4BNN1/1P5P/R2Q1RK1 w kq - 0 16}}
        {mg-late     middlegame 0 {3Qb1k1/1r2ppb1/pN1n2q1/Pp1Pp1Pr/4P2p/4BP2/4B1R1/1R5K b - - 11 40}}
        {eg-rooks    endgame    0 {4k2r/1pb2ppp/1p2p3/1R1p4/3P4/2r1PN2/P4PPP/1R4K1 b - - 3 22}}
        {eg-queens   endgame    1 {3q2k1/pb3p1p/4pbp1/2r5/PpN2N2/1P2P2P/5PP1/Q2R2K1 b - - 4 26}}
        {eg-rook     endgame    0 {8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 11}}
        {eg-rb       endgame    0 {6k1/4pp1p/3p2p1/P1pPb3/R7/1r2P1PP/3B1P2/6K1 w - - 0 1}}
        {eg-pawns    endgame    0 {8/1p3pp1/7p/5P1P/2k3P1/8/2K2P2/8 w - - 0 1}}
        {eg-rp       endgame    0 {8/pp2r1k1/2p1p3/3pP2p/1P1P1P1P/P5KR/8/8 w - - 0 1}}
    }
}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

proc ::enginebench::log {msg} {
    variable logCmd
    if {$logCmd ne ""} {
        catch {{*}$logCmd $msg}
    } else {
        catch {puts stderr $msg; flush stderr}
    }
}

proc ::enginebench::requestCancel {} {
    variable cancel 1
    variable Sig
    foreach ch [array names Sig] { incr Sig($ch) }
}

proc ::enginebench::mean {l} {
    if {![llength $l]} { return 0.0 }
    set s 0.0
    foreach x $l { set s [expr {$s + $x}] }
    expr {$s / [llength $l]}
}

proc ::enginebench::sd {l} {
    set n [llength $l]
    if {$n < 2} { return 0.0 }
    set m [mean $l]
    set s 0.0
    foreach x $l { set s [expr {$s + ($x - $m) ** 2}] }
    expr {sqrt($s / ($n - 1))}
}

proc ::enginebench::geomean {l} {
    set logs {}
    foreach x $l { if {$x > 0} { lappend logs [expr {log($x)}] } }
    if {![llength $logs]} { return 0.0 }
    expr {exp([mean $logs])}
}

proc ::enginebench::slurp {path} {
    if {[catch {open $path r} f]} { return "" }
    set data [read $f]
    close $f
    return $data
}

proc ::enginebench::tryExec {args} {
    if {[catch {exec {*}$args 2>@1} out]} { return "" }
    return $out
}

proc ::enginebench::positionSet {{which all}} {
    variable positions
    set res {}
    foreach p $positions {
        lassign $p name phase cb fen
        if {$which eq "cb" && !$cb} { continue }
        lappend res [dict create name $name phase $phase cb $cb fen $fen]
    }
    return $res
}

# Read positions from an EPD or FEN file, one per line.
proc ::enginebench::loadPositions {path} {
    set res {}
    set n 0
    foreach line [split [slurp $path] \n] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        incr n
        set f [regexp -all -inline {\S+} $line]
        if {[llength $f] < 4} { continue }
        set fen [join [lrange $f 0 3]]
        if {[string is integer -strict [lindex $f 4]] && [string is integer -strict [lindex $f 5]]} {
            append fen " [lindex $f 4] [lindex $f 5]"
        } else {
            append fen " 0 1"
        }
        set name "pos$n"
        regexp {id "([^"]*)"} $line -> name
        lappend res [dict create name $name phase file cb [expr {$n <= 4}] fen $fen]
    }
    if {![llength $res]} { error "no positions found in $path" }
    return $res
}

# --------------------------------------------------------------------------
# System information and per-OS checks
# --------------------------------------------------------------------------

proc ::enginebench::sysinfo {} {
    set d [dict create os $::tcl_platform(os) osVersion $::tcl_platform(osVersion) \
            machine $::tcl_platform(machine) platform $::tcl_platform(platform) \
            cpu "" logical 0 physical 0 pcores 0 ramMB 0]
    switch -glob -- $::tcl_platform(os) {
        Linux {
            set info [slurp /proc/cpuinfo]
            regexp -line {^model name\s*:\s*(.+)$} $info -> cpu
            if {[info exists cpu]} { dict set d cpu [string trim $cpu] }
            dict set d logical [regexp -all -line {^processor\s*:} $info]
            set cores {}
            set phys ""
            foreach line [split $info \n] {
                if {[regexp {^physical id\s*:\s*(\d+)} $line -> phys]} { continue }
                if {[regexp {^core id\s*:\s*(\d+)} $line -> core]} { dict set cores "$phys/$core" 1 }
            }
            dict set d physical [dict size $cores]
            if {[regexp -line {^MemTotal:\s*(\d+)} [slurp /proc/meminfo] -> kb]} {
                dict set d ramMB [expr {$kb / 1024}]
            }
        }
        Darwin {
            dict set d cpu [string trim [tryExec sysctl -n machdep.cpu.brand_string]]
            foreach {key sys} {logical hw.logicalcpu physical hw.physicalcpu pcores hw.perflevel0.physicalcpu} {
                set v [string trim [tryExec sysctl -n $sys]]
                if {[string is integer -strict $v]} { dict set d $key $v }
            }
            set v [string trim [tryExec sysctl -n hw.memsize]]
            if {[string is entier -strict $v]} { dict set d ramMB [expr {$v / 1048576}] }
        }
        Windows* {
            if {[info exists ::env(PROCESSOR_IDENTIFIER)]} { dict set d cpu $::env(PROCESSOR_IDENTIFIER) }
            if {[info exists ::env(NUMBER_OF_PROCESSORS)]} { dict set d logical $::env(NUMBER_OF_PROCESSORS) }
            set ps {$p=@(Get-CimInstance Win32_Processor); ($p|Measure-Object NumberOfCores -Sum).Sum; ($p|Measure-Object NumberOfLogicalProcessors -Sum).Sum; (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory; $p[0].Name}
            set out [split [string trim [tryExec powershell -NoProfile -NonInteractive -Command $ps]] \n]
            if {[llength $out] >= 4} {
                lassign $out phys logi mem name
                foreach v {phys logi mem name} { set $v [string trim [set $v]] }
                if {[string is integer -strict $phys]} { dict set d physical $phys }
                if {[string is integer -strict $logi]} { dict set d logical $logi }
                if {[string is entier -strict $mem]} { dict set d ramMB [expr {$mem / 1048576}] }
                if {$name ne ""} { dict set d cpu $name }
            }
        }
    }
    if {[dict get $d logical] < 1} { dict set d logical 1 }
    if {[dict get $d physical] < 1} { dict set d physical [dict get $d logical] }
    return $d
}

# Things outside the UCI options that change engine speed, per operating
# system. Returns a list of {level text}; level is ok, info or warn.
proc ::enginebench::systemChecks {sys} {
    set res {}
    set logical [dict get $sys logical]
    set physical [dict get $sys physical]
    if {$logical > $physical} {
        lappend res [list info "SMT/Hyper-Threading is on ($physical cores, $logical threads). Stockfish's documentation reports SMT as beneficial, so thread counts above $physical are tried."]
    }
    switch -glob -- [dict get $sys os] {
        Linux {
            set thp [slurp /sys/kernel/mm/transparent_hugepage/enabled]
            if {[regexp {\[(\w+)\]} $thp -> mode]} {
                if {$mode eq "never"} {
                    lappend res [list warn "Transparent huge pages are disabled (never). Stockfish gets large pages through THP on Linux; set it to madvise or always (echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled)."]
                } else {
                    lappend res [list ok "Transparent huge pages: $mode (large pages available to the engine)."]
                }
            }
            set gov [string trim [slurp /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor]]
            if {$gov ne "" && $gov ne "performance"} {
                lappend res [list info "CPU frequency governor is '$gov'. 'performance' removes ramp-up noise from short measurements."]
            }
        }
        Darwin {
            lappend res [list info "Stockfish supports large pages on Linux and Windows only, so there is nothing to enable on macOS."]
            set pc [dict get $sys pcores]
            if {$pc > 0 && $pc < $physical} {
                lappend res [list info "Asymmetric CPU: $pc performance cores out of $physical. Threads=$pc is tried as a candidate, because threads placed on efficiency cores are slower."]
            }
        }
        Windows* {
            set priv [tryExec whoami /priv]
            if {$priv ne ""} {
                if {[string match *SeLockMemoryPrivilege* $priv]} {
                    lappend res [list ok "'Lock pages in memory' is granted: the engine can use large pages."]
                } else {
                    lappend res [list warn "'Lock pages in memory' is not granted, so the engine cannot use large pages (Stockfish's documentation: typically 5-10% nodes/second, more with a large hash). Grant it in secpol.msc -> Local Policies -> User Rights Assignment, then sign out or reboot."]
                }
            }
            set plan [tryExec powercfg /getactivescheme]
            if {[regexp {\(([^)]*)\)\s*$} [string trim $plan] -> planName]} {
                lappend res [list info "Active power plan: $planName. Use a high-performance plan and mains power while measuring."]
            }
            lappend res [list info "On hybrid CPUs (Intel 12th gen and later) Windows may schedule the engine on efficiency cores; Stockfish's documentation suggests priority 'Above normal' or an affinity limited to performance cores."]
        }
    }
    lappend res [list info "Close other programs while measuring; the Stockfish documentation treats differences below roughly 0.3% as noise."]
    return $res
}

# --------------------------------------------------------------------------
# UCI engine process
# --------------------------------------------------------------------------

proc ::enginebench::engOpen {cmd {dir ""}} {
    variable Q
    variable Sig
    variable Eof
    variable Last
    set old [pwd]
    if {$dir ne ""} { catch {cd $dir} }
    set rc [catch {open |[list $cmd 2>@1] r+} ch]
    catch {cd $old}
    if {$rc} { error "cannot start engine '$cmd': $ch" }
    fconfigure $ch -blocking 0 -buffering line -translation auto -encoding utf-8
    set Q($ch) {}
    set Sig($ch) 0
    set Eof($ch) 0
    set Last($ch) {}
    fileevent $ch readable [list ::enginebench::engRead $ch]
    return $ch
}

proc ::enginebench::engRead {ch} {
    variable Q
    variable Sig
    variable Eof
    while {[gets $ch line] >= 0} {
        lappend Q($ch) [list [clock microseconds] [string trim $line]]
    }
    if {[eof $ch]} {
        set Eof($ch) 1
        fileevent $ch readable {}
    }
    incr Sig($ch)
}

proc ::enginebench::engSend {ch line} {
    if {[catch {puts $ch $line; flush $ch} err]} {
        error "engine is not accepting commands: $err"
    }
}

# Wait for a line starting with $prefix. Returns {microseconds line}.
proc ::enginebench::engExpect {ch prefix timeout {lineCb ""}} {
    variable Q
    variable Sig
    variable Eof
    variable cancel
    set deadline [expr {[clock milliseconds] + $timeout}]
    while 1 {
        while {[llength $Q($ch)]} {
            set Q($ch) [lassign $Q($ch) item]
            if {$lineCb ne ""} { {*}$lineCb {*}$item }
            if {[string match "${prefix}*" [lindex $item 1]]} { return $item }
        }
        if {$Eof($ch)} { error "engine terminated unexpectedly" }
        if {$cancel} { return -code error -errorcode {ENGINEBENCH CANCEL} "cancelled" }
        set left [expr {$deadline - [clock milliseconds]}]
        if {$left <= 0} { error "timeout waiting for '$prefix' from the engine" }
        set timer [after [expr {min($left, 200)}] [list incr ::enginebench::Sig($ch)]]
        vwait ::enginebench::Sig($ch)
        after cancel $timer
    }
}

proc ::enginebench::engClose {ch} {
    variable Q
    variable Sig
    variable Eof
    variable Last
    catch {fileevent $ch readable {}}
    catch {puts $ch stop; puts $ch quit; flush $ch}
    catch {close $ch}
    unset -nocomplain Q($ch) Sig($ch) Eof($ch) Last($ch)
}

# Start the engine and return {channel name options}; options maps each UCI
# option name to {type default min max vars}.
proc ::enginebench::engStart {cmd {dir ""}} {
    set ch [engOpen $cmd $dir]
    set name [file tail $cmd]
    set opts {}
    if {[catch {
        engSend $ch uci
        set collect [list apply {{nameVar optsVar us line} {
            upvar #0 $nameVar name $optsVar opts
            if {[regexp {^id name (.+)$} $line -> n]} { set name $n }
            if {[regexp {^option name (.+?) type (\S+)(.*)$} $line -> oname type rest]} {
                set def ""; set min ""; set max ""
                regexp { default (\S*)} $rest -> def
                regexp { min (-?\d+)} $rest -> min
                regexp { max (-?\d+)} $rest -> max
                set vars {}
                foreach {- v} [regexp -all -inline { var (\S+)} $rest] { lappend vars $v }
                dict set opts $oname [list $type $def $min $max $vars]
            }
        }} ::enginebench::_name ::enginebench::_opts]
        set ::enginebench::_name $name
        set ::enginebench::_opts {}
        engExpect $ch uciok 20000 $collect
        set name $::enginebench::_name
        set opts $::enginebench::_opts
    } err opt]} {
        engClose $ch
        return -options $opt $err
    }
    return [list $ch $name $opts]
}

# Describe an engine without searching: {name options}.
proc ::enginebench::probe {cmd {dir ""}} {
    lassign [engStart $cmd $dir] ch name opts
    engClose $ch
    return [list $name $opts]
}

proc ::enginebench::parseInfo {line} {
    if {![string match "info *" $line] || [string match "info string*" $line]} { return {} }
    set tok [regexp -all -inline {\S+} $line]
    set pv [lsearch -exact $tok pv]
    if {$pv >= 0} { set tok [lrange $tok 0 $pv-1] }
    set d {}
    foreach k {depth seldepth multipv nodes nps time hashfull tbhits} {
        set i [lsearch -exact $tok $k]
        if {$i >= 0} {
            set v [lindex $tok $i+1]
            if {[string is entier -strict $v]} { dict set d $k $v }
        }
    }
    set i [lsearch -exact $tok score]
    if {$i >= 0} { dict set d score "[lindex $tok $i+1] [lindex $tok $i+2]" }
    return $d
}

proc ::enginebench::infoCb {ch us line} {
    variable Last
    set d [parseInfo $line]
    if {![dict exists $d nodes]} { return }
    if {[dict exists $d multipv] && [dict get $d multipv] != 1} { return }
    set Last($ch) [dict merge $Last($ch) $d]
}

# Search one position. $limit is {movetime ms}, {depth plies} or {nodes n}.
proc ::enginebench::runPosition {ch pos limit} {
    variable Last
    lassign $limit kind val
    engSend $ch ucinewgame
    engSend $ch isready
    engExpect $ch readyok 120000
    set fen [dict get $pos fen]
    engSend $ch "position [expr {$fen eq "startpos" ? "startpos" : "fen $fen"}]"
    set Last($ch) {}
    set timeout [expr {$kind eq "movetime" ? $val + 30000 : 1800000}]
    set t0 [clock microseconds]
    engSend $ch "go $kind $val"
    lassign [engExpect $ch bestmove $timeout [list ::enginebench::infoCb $ch]] t1 best
    set wall [expr {($t1 - $t0) / 1000.0}]
    set r [dict merge {depth 0 seldepth 0 nodes 0 nps 0 time 0 hashfull 0 tbhits 0 score ""} $Last($ch)]
    set nodes [dict get $r nodes]
    if {[dict get $r nps] == 0 && $wall > 0} {
        dict set r nps [expr {int($nodes * 1000.0 / $wall)}]
    }
    dict set r wall_ms [format %.1f $wall]
    dict set r nps_wall [expr {$wall > 0 ? int($nodes * 1000.0 / $wall) : 0}]
    dict set r bestmove [lindex $best 1]
    dict set r name [dict get $pos name]
    dict set r phase [dict get $pos phase]
    dict set r cb [dict get $pos cb]
    dict set r fen $fen
    return $r
}

proc ::enginebench::aggregate {rows} {
    set nodes 0
    set wall 0.0
    set nps {}; set depth {}; set walls {}; set hf {}
    foreach r $rows {
        incr nodes [dict get $r nodes]
        set wall [expr {$wall + [dict get $r wall_ms]}]
        lappend nps [dict get $r nps]
        lappend depth [dict get $r depth]
        lappend walls [dict get $r wall_ms]
        lappend hf [dict get $r hashfull]
    }
    dict create positions [llength $rows] nodes_total $nodes \
        wall_total_ms [format %.0f $wall] \
        nps_overall [expr {$wall > 0 ? int($nodes * 1000.0 / $wall) : 0}] \
        nps_geomean [expr {int([geomean $nps])}] \
        depth_mean [format %.1f [mean $depth]] \
        wall_geomean_ms [format %.1f [geomean $walls]] \
        hashfull_mean [format %.0f [mean $hf]] \
        hashfull_max [lindex [lsort -integer $hf] end]
}

# Run a list of positions in a fresh engine process with the given options.
# cfg: dict {cmd dir options}. Returns {name rows agg options}.
proc ::enginebench::runSuite {cfg positions limit {label ""}} {
    lassign [engStart [dict get $cfg cmd] [dict get $cfg dir]] ch name known
    set rows {}
    set rc [catch {
        dict for {o v} [dict get $cfg options] {
            if {![dict exists $known $o]} {
                log "  note: engine has no option '$o', skipped"
                continue
            }
            engSend $ch "setoption name $o value $v"
        }
        engSend $ch isready
        engExpect $ch readyok 300000
        set i 0
        foreach pos $positions {
            incr i
            set r [runPosition $ch $pos $limit]
            lappend rows $r
            log [format "  %s%-11s depth %2d  %9.0f kN/s  %8.0f ms  hashfull %3d" \
                $label [dict get $r name] [dict get $r depth] \
                [expr {[dict get $r nps] / 1000.0}] [dict get $r wall_ms] [dict get $r hashfull]]
        }
    } err opt]
    engClose $ch
    if {$rc} { return -options $opt $err }
    return [dict create name $name rows $rows agg [aggregate $rows] options [dict get $cfg options]]
}

# Stockfish's own `bench` command (not part of UCI): {nodes time_ms nps}.
proc ::enginebench::runNativeBench {cfg hash threads depth} {
    lassign [engStart [dict get $cfg cmd] [dict get $cfg dir]] ch name known
    set rc [catch {
        engSend $ch "bench $hash $threads $depth"
        set ::enginebench::_bench {}
        set cb [list apply {{us line} {
            if {[regexp {^Total time \(ms\)\s*:\s*(\d+)} $line -> v]} { dict set ::enginebench::_bench time_ms $v }
            if {[regexp {^Nodes searched\s*:\s*(\d+)} $line -> v]} { dict set ::enginebench::_bench nodes $v }
            if {[regexp {^Nodes/second\s*:\s*(\d+)} $line -> v]} { dict set ::enginebench::_bench nps $v }
        }}]
        engExpect $ch "Nodes/second" 900000 $cb
    } err opt]
    engClose $ch
    if {$rc} { return -options $opt $err }
    return [dict merge [dict create hash $hash threads $threads depth $depth] $::enginebench::_bench]
}

# --------------------------------------------------------------------------
# Candidate values
# --------------------------------------------------------------------------

proc ::enginebench::threadCandidates {sys known} {
    set l [dict get $sys logical]
    set p [dict get $sys physical]
    set max $l
    if {[dict exists $known Threads]} {
        set m [lindex [dict get $known Threads] 3]
        if {[string is integer -strict $m] && $m < $max} { set max $m }
    }
    set c [list 1 [expr {$p / 2}] [expr {$p - 1}] $p [dict get $sys pcores] \
        [expr {($p + $l) / 2}] [expr {$l - 1}] $l]
    set res {}
    foreach v [lsort -integer -unique $c] {
        if {$v >= 1 && $v <= $max} { lappend res $v }
    }
    return $res
}

proc ::enginebench::hashCandidates {sys known} {
    set cap [expr {[dict get $sys ramMB] / 2}]
    if {$cap < 16} { set cap 1024 }
    if {[dict exists $known Hash]} {
        set m [lindex [dict get $known Hash] 3]
        if {[string is entier -strict $m] && $m < $cap} { set cap $m }
    }
    set res {}
    for {set h 16} {$h <= $cap && $h <= 65536} {set h [expr {$h * 4}]} { lappend res $h }
    if {![llength $res]} { set res 16 }
    return $res
}

# --------------------------------------------------------------------------
# Benchmark: several kinds of test, one report
# --------------------------------------------------------------------------

proc ::enginebench::defaultPlan {{profile standard}} {
    set plan [dict create profile $profile tests {movetime depth} movetime 5000 depth 20 \
        nodes 2000000 positions all scaling_movetime 3000 bench_depth 13]
    switch -- $profile {
        quick    { dict set plan tests movetime; dict set plan movetime 2000; dict set plan positions cb }
        standard { }
        full     { dict set plan tests {movetime depth nodes scaling bench} }
        default  { error "unknown profile '$profile' (quick, standard, full)" }
    }
    return $plan
}

proc ::enginebench::resolvePositions {spec} {
    if {$spec eq "all" || $spec eq "cb"} { return [positionSet $spec] }
    return [loadPositions $spec]
}

proc ::enginebench::benchmark {cfg plan} {
    variable cancel 0
    variable version
    set sys [sysinfo]
    lassign [probe [dict get $cfg cmd] [dict get $cfg dir]] name known
    log "Engine: $name"
    set positions [resolvePositions [dict get $plan positions]]
    set rep [dict create kind benchmark version $version \
        date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] \
        engine $name cmd [dict get $cfg cmd] options [dict get $cfg options] \
        known $known system $sys checks [systemChecks $sys] plan $plan tests {}]
    foreach test [dict get $plan tests] {
        switch -- $test {
            movetime - depth - nodes {
                set val [dict get $plan $test]
                log "Test '$test' = $val on [llength $positions] positions"
                set s [runSuite $cfg $positions [list $test $val]]
                dict lappend rep tests [dict create type $test value $val rows [dict get $s rows] agg [dict get $s agg]]
            }
            scaling {
                set sub {}
                foreach p $positions { if {[dict get $p cb]} { lappend sub $p } }
                if {![llength $sub]} { set sub [lrange $positions 0 3] }
                set rows {}
                set base 0
                foreach t [threadCandidates $sys $known] {
                    log "Thread scaling: Threads=$t"
                    set c $cfg
                    dict set c options Threads $t
                    set s [runSuite $c $sub [list movetime [dict get $plan scaling_movetime]]]
                    set nps [dict get $s agg nps_geomean]
                    if {$base == 0} { set base [expr {double($nps) / $t}] }
                    lappend rows [dict create threads $t nps $nps \
                        speedup [format %.2f [expr {$nps / ($base > 0 ? $base : 1.0)}]] \
                        efficiency [format %.0f [expr {100.0 * $nps / ($base > 0 ? $base * $t : 1.0)}]]]
                }
                dict lappend rep tests [dict create type scaling value [dict get $plan scaling_movetime] rows $rows agg {}]
            }
            bench {
                if {![string match -nocase "stockfish*" $name]} {
                    log "Native bench skipped: '$name' is not Stockfish"
                    continue
                }
                set o [dict get $cfg options]
                set h [expr {[dict exists $o Hash] ? [dict get $o Hash] : 16}]
                set t [expr {[dict exists $o Threads] ? [dict get $o Threads] : 1}]
                log "Native 'bench $h $t [dict get $plan bench_depth]'"
                set b [runNativeBench $cfg $h $t [dict get $plan bench_depth]]
                dict lappend rep tests [dict create type bench value [dict get $plan bench_depth] rows [list $b] agg {}]
            }
            default { error "unknown test '$test'" }
        }
    }
    return $rep
}

# --------------------------------------------------------------------------
# Tuning: search the option space by repeated measurement
# --------------------------------------------------------------------------

# Per-position mean of the log objective (higher is better).
proc ::enginebench::tuneEval {cfg positions limit objective repeats label} {
    set sums {}
    for {set r 0} {$r < $repeats} {incr r} {
        set s [runSuite $cfg $positions $limit $label]
        set i 0
        foreach row [dict get $s rows] {
            if {$objective eq "ttd"} {
                set v [expr {-log(max([dict get $row wall_ms], 0.001))}]
            } else {
                set v [expr {log(max([dict get $row nps], 1))}]
            }
            dict lappend sums $i $v
            incr i
        }
    }
    set res {}
    dict for {i vals} $sums { lappend res [mean $vals] }
    return $res
}

# Paired comparison over positions: {gain_fraction t}.
proc ::enginebench::tuneCompare {cand inc} {
    set d {}
    foreach a $cand b $inc { lappend d [expr {$a - $b}] }
    set m [mean $d]
    set se [expr {[sd $d] / sqrt(max([llength $d], 1))}]
    set t [expr {$se > 0 ? $m / $se : ($m > 0 ? 99.0 : 0.0)}]
    list [expr {exp($m) - 1.0}] $t [expr {$se}]
}

# cfg: {cmd dir options}; t: dict with objective (nps|ttd), repeats, movetime,
# depth, positions, params (dict name -> candidate list, empty = automatic),
# hash_rule (hashfull|sweep|off), target_time, min_gain.
proc ::enginebench::tune {cfg t} {
    variable cancel 0
    variable version
    set t [dict merge {objective nps repeats 2 movetime 2000 depth 18 positions cb params {}
        hash_rule hashfull target_time 10000 min_gain 0.01 passes 2} $t]
    set sys [sysinfo]
    lassign [probe [dict get $cfg cmd] [dict get $cfg dir]] name known
    log "Engine: $name"
    set positions [resolvePositions [dict get $t positions]]
    set objective [dict get $t objective]
    set limit [expr {$objective eq "ttd" ? [list depth [dict get $t depth]] : [list movetime [dict get $t movetime]]}]

    # Search space.
    set space [dict get $t params]
    if {![dict size $space]} {
        if {[dict exists $known Threads]} { dict set space Threads [threadCandidates $sys $known] }
        if {[dict exists $known Hash] && [dict get $t hash_rule] eq "sweep"} {
            dict set space Hash [hashCandidates $sys $known]
        }
    }
    dict for {p cands} $space {
        if {![dict exists $known $p]} {
            log "Option '$p' is not offered by this engine, dropped"
            dict unset space $p
        }
    }

    # Starting point: the caller's options, engine defaults for the rest.
    set best [dict get $cfg options]
    dict for {p cands} $space {
        if {![dict exists $best $p]} { dict set best $p [lindex [dict get $known $p] 1] }
    }
    set baseline $best
    set trials {}
    set cache {}
    set evalCfg [list apply {{cfg positions limit objective repeats opts} {
        upvar 1 cache cache
        set key [lsort -stride 2 -index 0 $opts]
        if {![dict exists $cache $key]} {
            dict set cfg options $opts
            dict set cache $key [::enginebench::tuneEval $cfg $positions $limit $objective $repeats ""]
        }
        dict get $cache $key
    }} $cfg $positions $limit $objective [dict get $t repeats]]

    log "Baseline: $baseline"
    set inc [{*}$evalCfg $baseline]
    set baseScores $inc
    lappend trials [dict create options $baseline score [format %.4g [expr {exp([mean $inc])}]] gain 0.0 t 0.0 verdict baseline]

    for {set pass 1} {$pass <= [dict get $t passes]} {incr pass} {
        set changed 0
        dict for {p cands} $space {
            set winner ""
            set winGain 0.0
            set winScores {}
            foreach v $cands {
                if {$v eq [dict get $best $p]} { continue }
                set opts $best
                dict set opts $p $v
                log "Pass $pass: $p=$v"
                set sc [{*}$evalCfg $opts]
                lassign [tuneCompare $sc $inc] gain tval
                set ok [expr {$gain > [dict get $t min_gain] && $tval >= 2.0}]
                lappend trials [dict create options $opts score [format %.4g [expr {exp([mean $sc])}]] \
                    gain [format %.2f [expr {100 * $gain}]] t [format %.1f $tval] \
                    verdict [expr {$ok ? "better" : "not better"}]]
                if {$ok && $gain > $winGain} {
                    set winner $v; set winGain $gain; set winScores $sc
                }
            }
            if {$winner ne ""} {
                dict set best $p $winner
                set inc $winScores
                set changed 1
                log [format "  -> %s=%s (+%.1f%%)" $p $winner [expr {100 * $winGain}]]
            }
        }
        if {!$changed || [dict size $space] < 2} { break }
    }

    # Hash by the hashfull rule: the smallest size that stays under 30% full
    # for the intended analysis time (Stockfish "Useful data": strength drops
    # when the average hashfull exceeds ~30%).
    set hashRows {}
    if {[dict get $t hash_rule] eq "hashfull" && [dict exists $known Hash] && ![dict exists [dict get $t params] Hash]} {
        set sub [lrange $positions 0 2]
        set chosen ""
        foreach h [hashCandidates $sys $known] {
            set c $cfg
            dict set c options [dict merge $best [dict create Hash $h]]
            log "Hash sizing: Hash=$h for [dict get $t target_time] ms"
            set s [runSuite $c $sub [list movetime [dict get $t target_time]]]
            set hf [dict get $s agg hashfull_mean]
            lappend hashRows [dict create hash $h hashfull $hf nps [dict get $s agg nps_geomean]]
            set chosen $h
            if {$hf <= 300} { break }
        }
        if {$chosen ne ""} { dict set best Hash $chosen }
    }

    lassign [tuneCompare $inc $baseScores] gain tval se
    return [dict create kind tuning version $version \
        date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"] \
        engine $name cmd [dict get $cfg cmd] options [dict get $cfg options] known $known \
        system $sys checks [systemChecks $sys] settings $t space $space \
        baseline $baseline best $best trials $trials hash $hashRows \
        gain [format %.2f [expr {100 * $gain}]] \
        gain_err [format %.2f [expr {100 * 2 * $se}]] limit $limit]
}

# --------------------------------------------------------------------------
# Reports: one document model, rendered as Markdown, HTML and JSON
# --------------------------------------------------------------------------

proc ::enginebench::kn {nps} { format %.0f [expr {$nps / 1000.0}] }

proc ::enginebench::optText {opts} {
    set l {}
    dict for {k v} $opts { lappend l "$k=$v" }
    expr {[llength $l] ? [join $l ", "] : "engine defaults"}
}

# Returns a list of blocks: {h text} {p text} {table headers rows}
# {cb headers rows} (the ChessBase sheet; last column is filled in by hand).
proc ::enginebench::document {rep} {
    set sys [dict get $rep system]
    set doc {}
    set kind [dict get $rep kind]
    lappend doc [list h1 "Engine Speed Lab - $kind report"]
    lappend doc [list table {Item Value} [list \
        [list Engine [dict get $rep engine]] \
        [list Command [dict get $rep cmd]] \
        [list Options [optText [dict get $rep options]]] \
        [list Date [dict get $rep date]] \
        [list System "[dict get $sys os] [dict get $sys osVersion] ([dict get $sys machine])"] \
        [list CPU [dict get $sys cpu]] \
        [list Cores "[dict get $sys physical] physical, [dict get $sys logical] logical"] \
        [list RAM "[dict get $sys ramMB] MB"]]]
    lappend doc [list h2 "System checks"]
    set rows {}
    foreach c [dict get $rep checks] { lappend rows [list [lindex $c 0] [lindex $c 1]] }
    lappend doc [list table {Level Finding} $rows]

    if {$kind eq "benchmark"} {
        foreach test [dict get $rep tests] {
            set type [dict get $test type]
            set val [dict get $test value]
            switch -- $type {
                movetime - depth - nodes {
                    set unit [dict get {movetime " ms" depth " plies" nodes " nodes"} $type]
                    lappend doc [list h2 "Fixed $type: $val$unit per position"]
                    set rows {}
                    set cbRows {}
                    foreach r [dict get $test rows] {
                        lappend rows [list [dict get $r name] [dict get $r phase] [dict get $r depth] \
                            [dict get $r nodes] [kn [dict get $r nps]] [dict get $r wall_ms] \
                            [dict get $r hashfull] [dict get $r score] [dict get $r bestmove]]
                        if {[dict get $r cb]} {
                            lappend cbRows [list [dict get $r name] [dict get $r fen] \
                                [dict get $r depth] [kn [dict get $r nps]] ""]
                        }
                    }
                    lappend doc [list table {Position Phase Depth Nodes kN/s {Time ms} Hashfull Score Best} $rows]
                    set a [dict get $test agg]
                    lappend doc [list p "Overall [kn [dict get $a nps_overall]] kN/s (total nodes / total time), geometric mean [kn [dict get $a nps_geomean]] kN/s, mean depth [dict get $a depth_mean], geometric mean time [dict get $a wall_geomean_ms] ms, hash full mean [dict get $a hashfull_mean] permille / max [dict get $a hashfull_max] permille."]
                    if {$type eq "movetime" && [llength $cbRows]} {
                        lappend doc [list h2 "ChessBase comparison sheet"]
                        lappend doc [list p "In ChessBase load the same engine binary with the same options ([optText [dict get $rep options]]), one line (MultiPV 1) and no other engine running. Paste each FEN, start the analysis, and after [format %g [expr {$val / 1000.0}]] s read the kN/s and depth shown in the engine pane. Both numbers come from the engine's own UCI output, so they are directly comparable; a few percent of difference is measurement noise."]
                        lappend doc [list cb {Position FEN Depth {kN/s here} {kN/s ChessBase}} $cbRows]
                    }
                }
                scaling {
                    lappend doc [list h2 "Thread scaling ($val ms per position)"]
                    set rows {}
                    foreach r [dict get $test rows] {
                        lappend rows [list [dict get $r threads] [kn [dict get $r nps]] \
                            [dict get $r speedup] "[dict get $r efficiency]%"]
                    }
                    lappend doc [list table {Threads kN/s {Speed-up} {Efficiency per thread}} $rows]
                    lappend doc [list p "Speed-up is in nodes per second. With Lazy SMP the gain in playing strength is smaller than the gain in nodes per second."]
                }
                bench {
                    set b [lindex [dict get $test rows] 0]
                    lappend doc [list h2 "Engine's own bench"]
                    lappend doc [list table {Command Nodes {Time ms} kN/s} [list [list \
                        "bench [dict get $b hash] [dict get $b threads] [dict get $b depth]" \
                        [dict get $b nodes] [dict get $b time_ms] [kn [dict get $b nps]]]]]
                }
            }
        }
    } else {
        set s [dict get $rep settings]
        lappend doc [list h2 "Result"]
        lappend doc [list table {Configuration Options} [list \
            [list Baseline [optText [dict get $rep baseline]]] \
            [list Tuned [optText [dict get $rep best]]]]]
        set what [expr {[dict get $s objective] eq "ttd" ? "time to depth [lindex [dict get $rep limit] 1]" : "nodes per second"}]
        lappend doc [list p "Measured gain over the baseline in $what: [dict get $rep gain]% +/- [dict get $rep gain_err]% (two standard errors over [llength [resolvePositions [dict get $s positions]]] positions, [dict get $s repeats] repeats each). A candidate replaces the current best only when its paired gain exceeds [format %.0f [expr {100 * [dict get $s min_gain]}]]% and two standard errors."]
        lappend doc [list h2 "Trials"]
        set rows {}
        foreach tr [dict get $rep trials] {
            lappend rows [list [optText [dict get $tr options]] [dict get $tr score] \
                [dict get $tr gain] [dict get $tr t] [dict get $tr verdict]]
        }
        set unit [expr {[dict get $s objective] eq "ttd" ? "1/ms" : "nodes/s"}]
        lappend doc [list table [list Options "Score ($unit)" {Gain % vs current best} t Verdict] $rows]
        if {[llength [dict get $rep hash]]} {
            lappend doc [list h2 "Hash sizing"]
            set rows {}
            foreach h [dict get $rep hash] {
                lappend rows [list [dict get $h hash] [dict get $h hashfull] [kn [dict get $h nps]]]
            }
            lappend doc [list table {{Hash MB} Hashfull kN/s} $rows]
            lappend doc [list p "Hash is the smallest size that stays at or below 300 permille full after [format %g [expr {[dict get $s target_time] / 1000.0}]] s of search. Analysing for longer than that needs proportionally more."]
        }
    }
    return $doc
}

proc ::enginebench::renderMarkdown {doc} {
    set out ""
    foreach b $doc {
        lassign $b type a rows
        switch -- $type {
            h1 { append out "# $a\n\n" }
            h2 { append out "## $a\n\n" }
            p  { append out "$a\n\n" }
            table - cb {
                append out "| [join $a { | }] |\n|[string repeat { --- |} [llength $a]]\n"
                foreach r $rows {
                    set cells {}
                    foreach c $r { lappend cells [string map {| \\|} $c] }
                    append out "| [join $cells { | }] |\n"
                }
                append out "\n"
            }
        }
    }
    return $out
}

proc ::enginebench::esc {s} {
    string map {& &amp; < &lt; > &gt; \" &quot;} $s
}

proc ::enginebench::renderHtml {doc} {
    set out "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n"
    append out "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    append out "<title>Engine Speed Lab</title>\n<style>\n"
    append out {body{font:15px/1.5 system-ui,sans-serif;margin:2rem auto;max-width:1100px;padding:0 1rem;color:#1c1c1c;background:#fafafa}
h1{font-size:1.5rem}h2{font-size:1.15rem;margin-top:2rem;border-bottom:1px solid #ccc;padding-bottom:.2rem}
.wrap{overflow-x:auto}table{border-collapse:collapse;font-variant-numeric:tabular-nums}
th,td{padding:.3rem .7rem;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}
th{background:#eee}td.n{text-align:right}td.fen{font-family:ui-monospace,monospace;font-size:.85em}
input{width:6rem;font:inherit}.warn{color:#a40000;font-weight:600}.ok{color:#1a6b1a}
@media(prefers-color-scheme:dark){body{background:#181818;color:#e4e4e4}th{background:#2a2a2a}th,td{border-color:#3a3a3a}h2{border-color:#444}.warn{color:#ff8a80}.ok{color:#8fd68f}input{background:#222;color:inherit;border:1px solid #555}}
}
    append out "</style></head><body>\n"
    foreach b $doc {
        lassign $b type a rows
        switch -- $type {
            h1 { append out "<h1>[esc $a]</h1>\n" }
            h2 { append out "<h2>[esc $a]</h2>\n" }
            p  { append out "<p>[esc $a]</p>\n" }
            table - cb {
                append out "<div class=\"wrap\"><table><tr>"
                foreach h $a { append out "<th>[esc $h]</th>" }
                append out "</tr>\n"
                foreach r $rows {
                    append out "<tr>"
                    set i 0
                    foreach c $r {
                        incr i
                        if {$type eq "cb" && $i == [llength $r]} {
                            append out "<td><input type=\"number\" data-ref=\"[esc [lindex $r end-1]]\" oninput=\"cmp(this)\"> <span></span></td>"
                        } elseif {$type eq "cb" && $i == 2} {
                            append out "<td class=\"fen\">[esc $c]</td>"
                        } elseif {$c in {warn ok}} {
                            append out "<td class=\"$c\">$c</td>"
                        } elseif {[string is double -strict $c]} {
                            append out "<td class=\"n\">[esc $c]</td>"
                        } else {
                            append out "<td>[esc $c]</td>"
                        }
                    }
                    append out "</tr>\n"
                }
                append out "</table></div>\n"
            }
        }
    }
    append out {<script>
function cmp(el){var ref=parseFloat(el.dataset.ref),v=parseFloat(el.value),s=el.nextElementSibling;
if(!ref||!v){s.textContent='';return}var d=(v/ref-1)*100;s.textContent=(d>=0?'+':'')+d.toFixed(1)+'% vs here';}
</script>
}
    append out "</body></html>\n"
    return $out
}

proc ::enginebench::jstr {s} {
    return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]\""
}

proc ::enginebench::jval {v} {
    if {[string is double -strict $v] && ![regexp -nocase {nan|inf|^0\d|^\+|^\.|\.$|x|^-0\d} $v]} { return $v }
    return [jstr $v]
}

proc ::enginebench::jdict {d} {
    set l {}
    dict for {k v} $d { lappend l "[jstr $k]: [jval $v]" }
    return "{[join $l {, }]}"
}

proc ::enginebench::jlist {dicts} {
    set l {}
    foreach d $dicts { lappend l [jdict $d] }
    return "\[[join $l ",\n    "]\]"
}

proc ::enginebench::renderJson {rep} {
    set l {}
    foreach k {kind version date engine cmd} { lappend l "[jstr $k]: [jstr [dict get $rep $k]]" }
    lappend l "\"options\": [jdict [dict get $rep options]]"
    lappend l "\"system\": [jdict [dict get $rep system]]"
    set checks {}
    foreach c [dict get $rep checks] { lappend checks [dict create level [lindex $c 0] text [lindex $c 1]] }
    lappend l "\"checks\": [jlist $checks]"
    if {[dict get $rep kind] eq "benchmark"} {
        set tests {}
        foreach t [dict get $rep tests] {
            lappend tests "{\"type\": [jstr [dict get $t type]], \"value\": [jval [dict get $t value]], \"aggregate\": [jdict [dict get $t agg]], \"rows\": [jlist [dict get $t rows]]}"
        }
        lappend l "\"tests\": \[[join $tests ",\n  "]\]"
    } else {
        lappend l "\"baseline\": [jdict [dict get $rep baseline]]"
        lappend l "\"best\": [jdict [dict get $rep best]]"
        lappend l "\"gain_percent\": [jval [dict get $rep gain]]"
        lappend l "\"gain_error_percent\": [jval [dict get $rep gain_err]]"
        set trials {}
        foreach t [dict get $rep trials] {
            set o [dict get $t options]
            dict unset t options
            lappend trials "{\"options\": [jdict $o], \"result\": [jdict $t]}"
        }
        lappend l "\"trials\": \[[join $trials ",\n  "]\]"
        lappend l "\"hash_sizing\": [jlist [dict get $rep hash]]"
    }
    return "{\n  [join $l ",\n  "]\n}\n"
}

# Write <dir>/<kind>-<timestamp>.{md,html,json}; returns the three paths.
proc ::enginebench::writeReports {rep dir} {
    file mkdir $dir
    set stem [file join $dir "[dict get $rep kind]-[clock format [clock seconds] -format %Y%m%d-%H%M%S]"]
    set doc [document $rep]
    set paths {}
    foreach {ext text} [list md [renderMarkdown $doc] html [renderHtml $doc] json [renderJson $rep]] {
        set f [open $stem.$ext w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $text
        close $f
        lappend paths $stem.$ext
    }
    return $paths
}

# --------------------------------------------------------------------------
# scidCommunity plugin window
# --------------------------------------------------------------------------

namespace eval ::enginebench::gui {
    variable w .enginebench
    variable v
    array set v {engine "" profile standard threads "" hash "" objective nps busy 0 report "" tuned "" tunedFrom ""}
}

proc ::enginebench::gui::engineNames {} {
    if {[catch {::enginecfg::names} names]} { return {} }
    return $names
}

# Resolve the Engine field to {cmd dir options name}: a scidCommunity preset
# name, or the path of an engine binary.
proc ::enginebench::gui::resolve {} {
    variable v
    set cfg ""
    catch { set cfg [::enginecfg::get $v(engine)] }
    if {$cfg ne ""} {
        set opts {}
        foreach o [lindex $cfg 8] { dict set opts [lindex $o 0] [lindex $o 1] }
        set res [list [lindex $cfg 1] [lindex $cfg 3] $opts [lindex $cfg 0]]
    } elseif {[file isfile $v(engine)]} {
        set res [list $v(engine) [file dirname $v(engine)] {} [file rootname [file tail $v(engine)]]]
    } else {
        error "Choose an engine from the list or browse to its executable."
    }
    lassign $res cmd dir opts name
    foreach {field opt} {threads Threads hash Hash} {
        set val [string trim $v($field)]
        if {$val eq ""} { continue }
        if {![string is integer -strict $val] || $val < 1} { error "$opt must be a positive whole number." }
        dict set opts $opt $val
    }
    return [list $cmd $dir $opts $name]
}

proc ::enginebench::gui::say {msg} {
    variable w
    if {![winfo exists $w.log]} { return }
    $w.log configure -state normal
    $w.log insert end "$msg\n"
    $w.log see end
    $w.log configure -state disabled
}

proc ::enginebench::gui::setBusy {busy} {
    variable w
    variable v
    set v(busy) $busy
    if {![winfo exists $w]} { return }
    foreach b {bench tune} { $w.b.$b configure -state [expr {$busy ? "disabled" : "normal"}] }
    $w.b.stop configure -state [expr {$busy ? "normal" : "disabled"}]
    $w.b.report configure -state [expr {!$busy && $v(report) ne "" ? "normal" : "disabled"}]
    $w.b.save configure -state [expr {!$busy && $v(tuned) ne "" ? "normal" : "disabled"}]
}

proc ::enginebench::gui::run {what} {
    variable v
    if {$v(busy)} { return }
    if {[catch {resolve} res]} {
        tk_messageBox -icon warning -type ok -title "Engine Speed Lab" -message $res
        return
    }
    lassign $res cmd dir opts name
    set cfg [dict create cmd $cmd dir $dir options $opts]
    set ::enginebench::logCmd ::enginebench::gui::say
    setBusy 1
    say "--- $what: $name ---"
    set rc [catch {
        if {$what eq "benchmark"} {
            set rep [::enginebench::benchmark $cfg [::enginebench::defaultPlan $v(profile)]]
        } else {
            set rep [::enginebench::tune $cfg [dict create objective $v(objective)]]
            set v(tuned) [dict get $rep best]
            set v(tunedFrom) $v(engine)
            say "Tuned options: [::enginebench::optText $v(tuned)] ([dict get $rep gain]% +/- [dict get $rep gain_err]%)"
        }
        set paths [::enginebench::writeReports $rep [file join $::scidUserDir enginebench]]
        set v(report) [lindex $paths 1]
        say "Report: $v(report)"
    } err opt]
    if {$rc} {
        if {[dict get $opt -errorcode] eq {ENGINEBENCH CANCEL}} {
            say "Stopped."
        } else {
            say "Error: $err"
        }
    }
    set ::enginebench::logCmd ""
    setBusy 0
}

proc ::enginebench::gui::openReport {} {
    variable v
    if {$v(report) eq ""} { return }
    if {[catch {
        switch -glob -- $::tcl_platform(os) {
            Windows* { exec {*}[auto_execok start] "" [file nativename $v(report)] & }
            Darwin   { exec open $v(report) & }
            default  { exec xdg-open $v(report) & }
        }
    } err]} {
        say "Cannot open the report automatically: $err"
    }
}

# Store the tuned options as a new engine preset, leaving the original alone.
proc ::enginebench::gui::savePreset {} {
    variable v
    if {$v(tuned) eq ""} { return }
    set cfg ""
    catch { set cfg [::enginecfg::get $v(tunedFrom)] }
    if {$cfg eq ""} {
        set cmd $v(tunedFrom)
        set cfg [list [file rootname [file tail $cmd]] $cmd "" [file dirname $cmd] 0 0 "" 1 {}]
    }
    set opts {}
    foreach o [lindex $cfg 8] {
        if {![dict exists $v(tuned) [lindex $o 0]]} { lappend opts [list [lindex $o 0] [lindex $o 1]] }
    }
    dict for {k val} $v(tuned) { lappend opts [list $k $val] }
    lset cfg 8 $opts
    lset cfg 0 "[lindex $cfg 0] (tuned)"
    if {[catch {::enginecfg::add $cfg} name] || $name eq ""} {
        say "Could not save the preset: $name"
        return
    }
    say "Saved engine preset '$name'."
    variable w
    catch { $w.f.engine configure -values [engineNames] }
}

proc ::enginebench::gui::browse {} {
    variable v
    variable w
    set f [tk_getOpenFile -parent $w -title "Engine executable"]
    if {$f ne ""} { set v(engine) $f }
}

proc ::enginebench::gui::open {} {
    variable w
    variable v
    if {[winfo exists $w]} { raise $w; focus $w; return }
    toplevel $w
    wm title $w "Engine Speed Lab"
    if {$v(engine) eq ""} { set v(engine) [lindex [engineNames] 0] }

    ttk::frame $w.f -padding 8
    ttk::label $w.f.le -text "Engine"
    ttk::combobox $w.f.engine -textvariable ::enginebench::gui::v(engine) -values [engineNames] -width 44
    ttk::button $w.f.browse -text "Browse..." -command ::enginebench::gui::browse
    ttk::label $w.f.lp -text "Benchmark"
    ttk::combobox $w.f.profile -textvariable ::enginebench::gui::v(profile) \
        -values {quick standard full} -state readonly -width 12
    ttk::label $w.f.lo -text "Tune for"
    ttk::combobox $w.f.objective -textvariable ::enginebench::gui::v(objective) \
        -values {nps ttd} -state readonly -width 12
    ttk::label $w.f.lt -text "Threads"
    ttk::entry $w.f.threads -textvariable ::enginebench::gui::v(threads) -width 8
    ttk::label $w.f.lh -text "Hash (MB)"
    ttk::entry $w.f.hash -textvariable ::enginebench::gui::v(hash) -width 8
    ttk::label $w.f.note -text "Threads and Hash: empty keeps the preset's (or the engine's) value."
    grid $w.f.le $w.f.engine - - $w.f.browse -sticky w -padx 3 -pady 3
    grid $w.f.lp $w.f.profile $w.f.lt $w.f.threads -sticky w -padx 3 -pady 3
    grid $w.f.lo $w.f.objective $w.f.lh $w.f.hash -sticky w -padx 3 -pady 3
    grid $w.f.note -columnspan 5 -sticky w -padx 3
    grid columnconfigure $w.f 3 -weight 1

    ttk::frame $w.b -padding {8 0 8 8}
    ttk::button $w.b.bench -text "Run benchmark" -command {::enginebench::gui::run benchmark}
    ttk::button $w.b.tune -text "Tune engine" -command {::enginebench::gui::run tuning}
    ttk::button $w.b.stop -text "Stop" -command ::enginebench::requestCancel
    ttk::button $w.b.report -text "Open report" -command ::enginebench::gui::openReport
    ttk::button $w.b.save -text "Save tuned preset" -command ::enginebench::gui::savePreset
    pack $w.b.bench $w.b.tune $w.b.stop $w.b.report $w.b.save -side left -padx 3

    ttk::frame $w.t -padding {8 0 8 8}
    text $w.log -height 20 -width 84 -state disabled -wrap none -yscrollcommand [list $w.sb set]
    ttk::scrollbar $w.sb -orient vertical -command [list $w.log yview]
    pack $w.sb -in $w.t -side right -fill y
    pack $w.log -in $w.t -side left -fill both -expand 1

    pack $w.f -fill x
    pack $w.b -fill x
    pack $w.t -fill both -expand 1
    wm protocol $w WM_DELETE_WINDOW {
        ::enginebench::requestCancel
        destroy $::enginebench::gui::w
    }
    setBusy 0
}

proc ::enginebench::gui::install {} {
    if {![winfo exists .menu.tools]} { return }
    .menu.tools add separator
    .menu.tools add command -label "Engine Speed Lab..." -command ::enginebench::gui::open
}

# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------

proc ::enginebench::usage {} {
    return {Engine Speed Lab - benchmark and tune a UCI chess engine

usage: tclsh 50_enginebench.tcl [options]

  --engine PATH        engine executable (default: $ENGINEBENCH_ENGINE, then
                       "stockfish" on the PATH)
  --option NAME=VALUE  UCI option to set; repeatable (e.g. --option Threads=8)
  --out DIR            report folder (default: ./enginebench-reports)
  --positions SPEC     all | cb | path to an EPD/FEN file (default: all)

Benchmark (default mode)
  --profile NAME       quick | standard | full (default: standard)
  --tests LIST         comma list of movetime,depth,nodes,scaling,bench
  --movetime MS        time per position for the movetime test
  --depth N            depth for the fixed-depth test
  --nodes N            node count for the fixed-nodes test

Tuning
  --tune               search the option space instead of benchmarking
  --objective NAME     nps (default) or ttd (time to depth)
  --param NAME=A,B,C   candidate values for an option; repeatable. Without
                       it, Threads is searched and Hash is sized by hashfull.
  --repeats N          measurements per candidate (default: 2)
  --hash-rule NAME     hashfull (default) | sweep | off
  --target-time MS     analysis time the Hash size is chosen for (10000)

  --list-options       print the engine's UCI options and exit
  --help               this text
}
}

proc ::enginebench::main {argv} {
    set cmd ""
    if {[info exists ::env(ENGINEBENCH_ENGINE)]} { set cmd $::env(ENGINEBENCH_ENGINE) }
    set opts {}
    set out [file join [pwd] enginebench-reports]
    set profile standard
    set over {}
    set tune 0
    set t {}
    set params {}
    set listOnly 0
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {$a in {--tune --list-options --help -h}} {
            switch -- $a {
                --tune { set tune 1 }
                --list-options { set listOnly 1 }
                default { puts [usage]; return 0 }
            }
            continue
        }
        if {$i + 1 >= [llength $argv]} { puts stderr "missing value for $a"; return 2 }
        set val [lindex $argv [incr i]]
        switch -- $a {
            --engine { set cmd $val }
            --option {
                if {![regexp {^([^=]+)=(.*)$} $val -> k x]} { puts stderr "--option needs NAME=VALUE"; return 2 }
                dict set opts $k $x
            }
            --out { set out $val }
            --profile { set profile $val }
            --positions { dict set over positions $val; dict set t positions $val }
            --tests { dict set over tests [split $val ,] }
            --movetime { dict set over movetime $val; dict set t movetime $val }
            --depth { dict set over depth $val; dict set t depth $val }
            --nodes { dict set over nodes $val }
            --objective { dict set t objective $val }
            --repeats { dict set t repeats $val }
            --hash-rule { dict set t hash_rule $val }
            --target-time { dict set t target_time $val }
            --param {
                if {![regexp {^([^=]+)=(.+)$} $val -> k x]} { puts stderr "--param needs NAME=A,B,C"; return 2 }
                dict set params $k [split $x ,]
            }
            default { puts stderr "unknown option $a (try --help)"; return 2 }
        }
    }
    if {$cmd eq ""} {
        set found [auto_execok stockfish]
        if {$found eq "" && [file executable /usr/games/stockfish]} { set found /usr/games/stockfish }
        set cmd [lindex $found 0]
    }
    if {$cmd eq ""} { puts stderr "no engine: use --engine PATH"; return 2 }
    set cfg [dict create cmd $cmd dir [file dirname $cmd] options $opts]

    if {$listOnly} {
        lassign [probe $cmd [dict get $cfg dir]] name known
        puts $name
        dict for {o spec} $known {
            lassign $spec type def min max vars
            puts [format "  %-24s %-7s default=%s%s%s" $o $type $def \
                [expr {$min ne "" ? " min=$min max=$max" : ""}] \
                [expr {[llength $vars] ? " values=[join $vars /]" : ""}]]
        }
        return 0
    }
    if {$tune} {
        if {[dict size $params]} { dict set t params $params }
        if {![dict exists $t positions]} { dict set t positions cb }
        set rep [tune $cfg $t]
        puts "Tuned options: [optText [dict get $rep best]]  (gain [dict get $rep gain]% +/- [dict get $rep gain_err]%)"
    } else {
        set rep [benchmark $cfg [dict merge [defaultPlan $profile] $over]]
    }
    foreach p [writeReports $rep $out] { puts "Report: $p" }
    return 0
}

if {[info exists ::scidUserDir] && [llength [info commands winfo]]} {
    ::enginebench::gui::install
} elseif {[info exists ::argv0] && [file normalize [info script]] eq [file normalize $::argv0]} {
    if {[catch {::enginebench::main $::argv} rc]} {
        puts stderr "error: $rc"
        exit 1
    }
    exit $rc
}
