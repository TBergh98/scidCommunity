# cb2_counts.tcl -- local check of the 2CBH importer (branch cb2Import).
# Prints counts only: no names, no moves, no comments.
#
#   scid-toolchain\scid.cmd <notes>\tools\cb2_counts.tcl D:\...\Mega2027.2cbh [more.2cbh ...]
#
# Each database is imported into a temporary SCID5 base, which is deleted
# afterwards. Expected (STATE.md / plan): Mega 2026 11,979,630 games,
# Mega 2027 12,603,309, the 20 Mega 2026 updates 122,352 in total.

set total 0
foreach db $argv {
    set tmp [file join [file dirname [info script]] "cb2_counts_tmp_[pid]"]
    set h [sc_base create SCID5 $tmp]
    set t0 [clock milliseconds]
    set rc [catch {sc_base import $h $db} res]
    set secs [expr {([clock milliseconds] - $t0) / 1000.0}]
    puts "== [file tail $db]"
    if {$rc} {
        puts "   import failed: $res"
    } else {
        lassign $res count messages
        incr total $count
        puts "   imported: $count games in $secs s"
        # The summary lines, then the problems grouped by reason (the
        # record numbers left out).
        array unset why
        foreach line [split $messages "\n"] {
            if {[regexp {^\(record \d+\) (.*)$} $line -> reason]} {
                incr why($reason)
            } elseif {$line ne ""} {
                puts "   $line"
            }
        }
        foreach reason [lsort [array names why]] {
            puts [format "   %8d x %s" $why($reason) $reason]
        }
    }
    sc_base close $h
    foreach f [glob -nocomplain "${tmp}.*"] { file delete -force $f }
}
puts "== total imported: $total"
exit 0
