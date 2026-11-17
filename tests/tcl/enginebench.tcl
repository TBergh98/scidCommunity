#!/usr/bin/env tclsh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Engine Speed Lab (plugins/50_enginebench.tcl): the UCI driver, the
# benchmark, the tuner and the report writers, run against a scripted engine
# so that the results are known in advance and no real engine is needed.

set fails 0
set checks 0

proc check {name cond} {
    global fails checks
    incr checks
    if {![uplevel 1 [list expr $cond]]} {
        incr fails
        puts "FAIL $name"
    }
}

proc checkEq {name got want} {
    global fails checks
    incr checks
    if {$got ne $want} {
        incr fails
        puts "FAIL $name -- got '$got' want '$want'"
    }
}

set root [file normalize [file join [file dirname [info script]] .. ..]]
source [file join $root plugins 50_enginebench.tcl]
set ::enginebench::logCmd {apply {{msg} {}}}

# A scripted UCI engine. Nodes/second peaks at Threads=3 and the hash fills
# in inverse proportion to its size, so the tuner has one right answer.
set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] enginebench-test-[pid]]
file mkdir $tmp
set f [open [file join $tmp fake.tcl] w]
puts $f {
    set threads 1
    set hash 16
    while {[gets stdin line] >= 0} {
        switch -glob -- $line {
            uci {
                puts "id name FakeFish 1.0"
                puts "option name Threads type spin default 1 min 1 max 8"
                puts "option name Hash type spin default 16 min 1 max 1024"
                puts "option name Style type combo default Solid var Solid var Risky"
                puts "uciok"
            }
            isready { puts readyok }
            "setoption name Threads value *" { set threads [lindex $line end] }
            "setoption name Hash value *" { set hash [lindex $line end] }
            "go *" {
                lassign [lrange $line 1 2] kind val
                set ms [expr {$kind eq "movetime" ? $val : 20}]
                after $ms
                set nps [expr {int(100000 * [dict get {1 1.0 2 2.0 3 3.0 4 2.5} $threads])}]
                set hf [expr {min(1000, 9600 / $hash)}]
                puts "info string not a search line"
                puts "info depth 9 multipv 2 score cp 1 nodes 1 nps 1 time 1 pv a2a3"
                puts "info depth 12 seldepth 18 multipv 1 score cp 31 nodes [expr {$nps * $ms / 1000}] nps $nps hashfull $hf time $ms pv e2e4 e7e5"
                puts "bestmove e2e4 ponder e7e5"
            }
            quit { exit }
        }
        flush stdout
    }
}
close $f
set engine [file join $tmp fakefish]
set f [open $engine w]
puts $f "#!/bin/sh\nexec [info nameofexecutable] [file join $tmp fake.tcl]"
close $f
file attributes $engine -permissions 0755
set cfg [dict create cmd $engine dir $tmp options {}]

# --- parsing -------------------------------------------------------------
set d [::enginebench::parseInfo "info depth 20 seldepth 31 multipv 1 score mate -3 nodes 1234 nps 99 hashfull 7 time 12 pv e2e4 depth 5"]
checkEq "info depth" [dict get $d depth] 20
checkEq "info nodes" [dict get $d nodes] 1234
checkEq "info score" [dict get $d score] "mate -3"
checkEq "info string ignored" [::enginebench::parseInfo "info string depth 3 nodes 4"] {}

# --- built-in positions --------------------------------------------------
set all [::enginebench::positionSet]
check "positions" {[llength $all] >= 12}
check "chessbase subset" {[llength [::enginebench::positionSet cb]] == 4}
foreach p $all {
    set fen [dict get $p fen]
    check "fen fields [dict get $p name]" {[llength $fen] == 6 && [llength [split [lindex $fen 0] /]] == 8}
}

# --- candidates ----------------------------------------------------------
set sys [dict create logical 16 physical 8 pcores 0 ramMB 32768]
set known [dict create Threads {spin 1 1 1024 {}} Hash {spin 16 1 33554432 {}}]
checkEq "thread candidates" [::enginebench::threadCandidates $sys $known] {1 4 7 8 12 15 16}
checkEq "thread candidates capped" \
    [::enginebench::threadCandidates $sys [dict create Threads {spin 1 1 4 {}}]] {1 4}
checkEq "hash candidates" [::enginebench::hashCandidates $sys $known] {16 64 256 1024 4096 16384}

# --- engine handshake ----------------------------------------------------
lassign [::enginebench::probe $engine $tmp] name opts
checkEq "engine name" $name "FakeFish 1.0"
checkEq "spin option" [dict get $opts Threads] {spin 1 1 8 {}}
checkEq "combo option" [dict get $opts Style] {combo Solid {} {} {Solid Risky}}
check "missing engine" {[catch {::enginebench::probe [file join $tmp nothing] $tmp}]}

# --- benchmark -----------------------------------------------------------
set plan [dict merge [::enginebench::defaultPlan quick] {movetime 40 tests {movetime depth nodes scaling bench}}]
dict set cfg options {Threads 2 Bogus 1}
set rep [::enginebench::benchmark $cfg $plan]
dict set cfg options {}
set tests [dict get $rep tests]
checkEq "tests run (bench is Stockfish-only)" [lmap t $tests {dict get $t type}] {movetime depth nodes scaling}
set mt [lindex $tests 0]
checkEq "rows" [llength [dict get $mt rows]] 4
set row [lindex [dict get $mt rows] 0]
checkEq "row nps: multipv 1 line, Threads=2" [dict get $row nps] 200000
checkEq "row depth" [dict get $row depth] 12
checkEq "row bestmove" [dict get $row bestmove] e2e4
check "row wall time" {[dict get $row wall_ms] >= 40 && [dict get $row wall_ms] < 2000}
checkEq "aggregate geomean" [dict get $mt agg nps_geomean] 200000
checkEq "aggregate hashfull" [dict get $mt agg hashfull_max] 600

set paths [::enginebench::writeReports $rep [file join $tmp out]]
checkEq "three reports" [lmap p $paths {file extension $p}] {.md .html .json}
set md [::enginebench::slurp [lindex $paths 0]]
check "markdown has the ChessBase sheet" {[string match "*ChessBase comparison sheet*" $md]}
check "markdown lists the start position" {[string match "*rnbqkbnr/pppppppp*" $md]}
set html [::enginebench::slurp [lindex $paths 1]]
check "html closes" {[string match "*</html>*" $html]}
check "html escapes" {![string match "*<script>alert*" [::enginebench::esc "<script>alert"]]}
set json [::enginebench::slurp [lindex $paths 2]]
checkEq "json braces balance" [regexp -all "\{" $json] [regexp -all "\}" $json]
check "json numbers stay numbers" {[string match {*"nps": 200000*} $json]}
checkEq "json string" [::enginebench::jval "e2e4"] "\"e2e4\""
checkEq "json quoting" [::enginebench::jstr "a\"b\\c"] "\"a\\\"b\\\\c\""

# --- tuning --------------------------------------------------------------
set rep [::enginebench::tune $cfg [dict create movetime 30 repeats 2 target_time 30 \
    params {Threads {1 2 3 4}}]]
checkEq "tuned Threads is the nps peak" [dict get $rep best Threads] 3
checkEq "Hash: smallest under 300 permille" [dict get $rep best Hash] 64
checkEq "baseline kept" [dict get $rep baseline] {Threads 1}
check "gain about 200%" {abs([dict get $rep gain] - 200) < 1}
checkEq "trials" [llength [dict get $rep trials]] 4
set paths [::enginebench::writeReports $rep [file join $tmp out]]
check "tuning report" {[string match "*Threads=3, Hash=64*" [::enginebench::slurp [lindex $paths 0]]]}

set rep [::enginebench::tune $cfg [dict create objective ttd depth 5 repeats 1 hash_rule off min_gain 0.5 \
    params {Threads {1 3} Nonexistent {1 2}}]]
checkEq "equal time to depth: nothing beats the baseline" [dict get $rep best] {Threads 1}

# --- cancel --------------------------------------------------------------
after 100 ::enginebench::requestCancel
set rc [catch {::enginebench::benchmark $cfg [dict merge [::enginebench::defaultPlan quick] {movetime 3000}]} err opt]
checkEq "cancel raises" [list $rc [dict get $opt -errorcode]] {1 {ENGINEBENCH CANCEL}}

# --- position files ------------------------------------------------------
set f [open [file join $tmp p.epd] w]
puts $f "# comment\n8/8/8/8/8/5k2/8/5K1R w - - bm Rh3+; id \"mate\";\nrnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3 7"
close $f
set ps [::enginebench::loadPositions [file join $tmp p.epd]]
checkEq "epd count" [llength $ps] 2
checkEq "epd fen padded" [dict get [lindex $ps 0] fen] "8/8/8/8/8/5k2/8/5K1R w - - 0 1"
checkEq "epd id" [dict get [lindex $ps 0] name] mate
checkEq "fen counters kept" [dict get [lindex $ps 1] fen] "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3 7"

# --- command line --------------------------------------------------------
checkEq "cli bad option" [::enginebench::main {--frobnicate 1}] 2

file delete -force $tmp
puts "$checks checks, $fails failed"
exit [expr {$fails > 0}]
