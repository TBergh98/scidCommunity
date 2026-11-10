# 30_lichess_study.tcl -- scidCommunity plugin
#
# Publishes games from a scidCommunity database as new chapters of one of
# your Lichess studies. It replaces "export PGN -> open Lichess -> find the
# study -> add chapter -> import PGN" with one dialog.
#
# Where to find it:
#   * Game List window: select one or more games, right click,
#     "Publish to Lichess study (N)...".
#   * Tools menu: "Publish current game to Lichess study..." publishes the
#     game on the board, unsaved changes included.
# The dialog also sets the board orientation and the chapter mode (normal
# analysis, hide next moves, practice with computer, interactive lesson).
#
# Install: copy this file into the "plugins" folder of your scidCommunity
# user folder (create the folder if it is missing) and restart.
#   Windows: %APPDATA%\scidCommunity\plugins
#   Linux:   ~/.scidX.Y/plugins  (X.Y = version, e.g. ~/.scid5.1/plugins)
#   macOS:   ~/Library/Application Support/scidCommunity/plugins
# Needs a scidCommunity that loads plugins, and curl (bundled with
# scidCommunity on Windows, preinstalled on macOS and most Linux systems).
#
# Lichess API used (https://lichess.org/api#tag/Studies):
#   GET  /api/account                -> your username
#   GET  /api/study/by/{username}    -> your studies, private too (study:read)
#   GET  /api/study/{id}.pgn         -> name of a study added by link (study:read)
#   POST /api/study/{id}/import-pgn  -> one chapter per game (study:write)
#   POST /api/study                  -> create a new study (study:write); it
#                                       starts with one empty chapter, which
#                                       is deleted after the import
#   DELETE /api/study/{id}/{chapter} -> that empty chapter (study:write)
# For a new study with 64 games the first game is imported before the empty
# chapter is deleted and the other 63 after, so that all of them fit.
# A study holds at most 64 chapters. Before publishing, the chapters of the
# study are counted (GET /api/study/{id}.pgn); if the games do not all fit
# the user can abort, publish only the first ones, or publish the first ones
# and put the rest in a new study (named in the dialog). Lichess itself imports games
# one by one until the limit and then answers HTTP 200 with error "Too many
# chapters"; the plugin shows that error in a dialog. Lichess has no endpoint listing the
# studies you only contribute to: add those once by pasting their link.
#
# Files kept in <user folder>/lichess_study/:
#   token.txt   your personal API token, in plain text
#   extra.txt   studies added by link (id <TAB> name, one per line; delete a
#               line to remove a study from the list)

namespace eval ::lichstudy {
    variable dir [file join $::scidUserDir lichess_study]
    variable maxChapters 64
    variable userAgent "scidCommunity-lichess-study-plugin"
    variable token ""
    variable studies {}     ;# {id name updatedAt byLink} for each study
    variable shown {}       ;# indexes into studies, in listbox order
    variable games {}       ;# the games to publish, one PGN text each
    variable filter ""
    variable orientation auto
    variable mode normal
    variable busy 0
    variable newName ""
    variable newVisibility private
    variable fresh {}       ;# {studyId emptyChapterId} of a study just created
    variable ovfAct split   ;# the "study is full" question (askOverflow)
    variable ovfName ""
    variable ovfMsg ""
    variable ovfDone 0
}

### Small helpers ###########################################################

proc ::lichstudy::readFile {path} {
    if {![file exists $path]} { return "" }
    set f [open $path r]
    fconfigure $f -encoding utf-8
    set data [read $f]
    close $f
    return $data
}

proc ::lichstudy::writeFile {path data} {
    file mkdir [file dirname $path]
    set f [open $path w]
    fconfigure $f -encoding utf-8 -translation lf
    puts -nonewline $f $data
    close $f
}

# Decodes a JSON string body (\" \\ \/ \n \uXXXX ...). subst runs with
# commands and variables disabled, so only backslash escapes are expanded.
proc ::lichstudy::unescape {s} {
    return [subst -nocommands -novariables $s]
}

# Opens a link in the browser. On Windows scidCommunity's openURL goes
# through "cmd /c start", which cuts URLs at the first "&".
proc ::lichstudy::openLink {url} {
    if {$::tcl_platform(platform) eq "windows"} {
        catch {exec rundll32 url.dll,FileProtocolHandler $url &}
    } else {
        openURL $url
    }
}

proc ::lichstudy::curlExe {} {
    set exe [auto_execok curl]
    if {$exe eq "" && [info exists ::scidExeDir]} {
        foreach name {curl.exe curl} {
            set c [file join $::scidExeDir $name]
            if {[file executable $c]} { return [list $c] }
        }
    }
    if {$exe eq ""} {
        error "curl not found: it is needed to talk to Lichess."
    }
    return $exe
}

# Calls the Lichess API with curl. Returns {httpCode body}.
# Extra curl arguments (e.g. --data-urlencode) make it a POST.
# The token is passed on stdin (-K -) so it never appears in the process
# list, and the body goes through a file so UTF-8 text survives on Windows.
proc ::lichstudy::api {url args} {
    variable token
    variable dir
    variable userAgent
    file mkdir $dir
    set out [file join $dir "reply_[pid].tmp"]
    set config ""
    if {$token ne ""} {
        append config "header = \"Authorization: Bearer $token\"\n"
    }
    set cmd [list {*}[curlExe] -s -S -K - --connect-timeout 15 --max-time 120 \
                 -A $userAgent -o $out -w "%{http_code}" {*}$args $url]
    set err [catch {exec {*}$cmd << $config} code]
    set body [readFile $out]
    file delete -force $out
    if {$err} { error "Network error: [string trim $code]" }
    return [list [string trim $code] $body]
}

# Clearer text for the Lichess error messages users are likely to meet.
proc ::lichstudy::friendly {msg} {
    variable maxChapters
    if {$msg eq "Too many chapters"} {
        return "the study is full: a Lichess study holds at most $maxChapters chapters."
    }
    return $msg
}

# Free chapter slots of study $id, or -1 if they cannot be counted (the
# caller then just publishes and reports what Lichess says).
proc ::lichstudy::freeChapters {id} {
    variable maxChapters
    if {[catch {api "https://lichess.org/api/study/$id.pgn?clocks=false&comments=false&variations=false"} r]
        || [lindex $r 0] ne "200"} {
        return -1
    }
    return [expr {$maxChapters - [regexp -all {\[ChapterURL } [lindex $r 1]]}]
}

proc ::lichstudy::errorText {code body} {
    if {[regexp {"error"\s*:\s*"((?:[^"\\]|\\.)*)"} $body -> msg]} {
        set msg [unescape $msg]
    } else {
        set msg ""
    }
    switch -- $code {
        000 { return "No answer from Lichess: check your internet connection." }
        401 { return "Invalid or expired token (401)." }
        403 { return "Permission denied (403): the token lacks the study:read/study:write scopes, or you cannot write to this study." }
        404 { return "Study not found (404), or it is private and you are not a member." }
        429 { return "Too many requests to Lichess (429): wait a minute and try again." }
    }
    if {$msg ne ""} { return "Lichess (HTTP $code): [friendly $msg]" }
    set body [string trim $body]
    if {[string length $body] > 200} { set body "[string range $body 0 199]..." }
    return "Unexpected answer from Lichess (HTTP $code). $body"
}

### Games -> PGN ############################################################

# Standard PGN for Lichess: NAGs as $n (Lichess shows them as !, ?!, +- ...),
# no column or indentation layout, and [%csl]/[%cal] marks kept so coloured
# squares and arrows appear in the study. -base/-gameNumber must come before
# these options, because sc_game pgn applies them to the game it selected.
proc ::lichstudy::pgnOptions {} {
    return {-width 80 -tags 1 -comments 1 -variations 1 -symbols 0
            -indentVariations 0 -indentComments 0 -space 0 -column 0
            -markCodes 0 -unicode 0 -format plain}
}

# Lichess splits a multi-game PGN at a blank line followed by "[", so the
# movetext of each game must not contain blank lines.
proc ::lichstudy::cleanGame {txt} {
    set txt [string trim [string map {"\r" ""} $txt]]
    set i [string first "\n\n" $txt]
    if {$i < 0} { return $txt }
    set head [string range $txt 0 [expr {$i - 1}]]
    set moves [string range $txt [expr {$i + 2}] end]
    regsub -all {\n(?:[ \t]*\n)+} $moves "\n" moves
    return "$head\n\n[string trim $moves]"
}

# PGN of game $num of base $base, read from the database without loading it
# (so the board, the current game and the current base stay as they are).
# The game on the board with unsaved changes is taken as shown on screen.
proc ::lichstudy::gamePgn {base num} {
    if {$base == [sc_base current] && $num == [sc_game number] && [sc_game altered]} {
        set txt [sc_game pgn {*}[pgnOptions]]
    } else {
        if {$num < 1 || $num > [sc_base numGames $base]} {
            error "Game $num not found in the database."
        }
        set txt [sc_game pgn -base $base -gameNumber $num {*}[pgnOptions]]
    }
    if {![string match {\[*} [string trimleft $txt]]} {
        error "Cannot read game $num: $txt"
    }
    return [cleanGame $txt]
}

# Game numbers from Game List item ids ("123" or "123_45").
proc ::lichstudy::selectionNumbers {items} {
    set nums {}
    foreach s $items {
        lassign [split [string trim $s] "_"] idx
        if {[string is integer -strict $idx] && $idx > 0 && $idx ni $nums} {
            lappend nums $idx
        }
    }
    return $nums
}

proc ::lichstudy::publishGames {base nums} {
    variable maxChapters
    if {![sc_base inUse $base]} {
        tk_messageBox -icon warning -title "Lichess study" -message "The database is no longer open."
        return
    }
    set n [llength $nums]
    if {$n == 0} { return }
    if {$n > $maxChapters} {
        tk_messageBox -icon warning -title "Lichess study" -message \
            "You selected $n games, but a Lichess study holds at most $maxChapters chapters."
        return
    }
    set games {}
    if {[catch {
        foreach num $nums { lappend games [gamePgn $base $num] }
    } msg]} {
        tk_messageBox -icon warning -title "Lichess study" -message $msg
        return
    }
    openDialog $games
}

proc ::lichstudy::publishCurrent {} {
    if {[sc_game number] == 0 && ![sc_game altered]} {
        tk_messageBox -icon info -title "Lichess study" -message \
            "There is no game on the board.\n\nTo publish games from a database, select them in the Game List and use the right-click menu."
        return
    }
    if {[catch {cleanGame [sc_game pgn {*}[pgnOptions]]} pgn]} {
        tk_messageBox -icon warning -title "Lichess study" -message $pgn
        return
    }
    openDialog [list $pgn]
}

### Studies #################################################################

proc ::lichstudy::loadStudies {} {
    variable studies
    variable dir
    set studies {}

    lassign [api https://lichess.org/api/account] code body
    if {$code ne "200"} { error [errorText $code $body] }
    if {![regexp {"username"\s*:\s*"([^"]+)"} $body -> user]} {
        error "Cannot read the username from the Lichess answer."
    }

    lassign [api https://lichess.org/api/study/by/$user] code body
    if {$code ne "200"} { error [errorText $code $body] }
    set own {}
    foreach line [split $body "\n"] {
        if {[regexp {"id"\s*:\s*"([^"]+)"} $line -> id]
            && [regexp {"name"\s*:\s*"((?:[^"\\]|\\.)*)"} $line -> nm]} {
            set up 0
            regexp {"updatedAt"\s*:\s*([0-9]+)} $line -> up
            lappend own [list $id [unescape $nm] $up 0]
        }
    }
    # Most recently updated first.
    set studies [lsort -integer -decreasing -index 2 $own]

    # Studies added by link (ones you contribute to but do not own).
    set ids [lmap s $studies {lindex $s 0}]
    foreach line [split [readFile [file join $dir extra.txt]] "\n"] {
        lassign [split $line "\t"] id nm
        set id [string trim $id]
        if {$id ne "" && $id ni $ids} {
            lappend studies [list $id $nm 0 1]
            lappend ids $id
        }
    }
    return $user
}

proc ::lichstudy::applyFilter {w} {
    variable studies
    variable shown
    variable filter
    if {![winfo exists $w.l.list]} { return }
    $w.l.list delete 0 end
    set shown {}
    set i 0
    foreach s $studies {
        lassign $s id nm up byLink
        if {$filter eq "" || [string first [string tolower $filter] [string tolower $nm]] >= 0} {
            if {$byLink} { append nm "   (added by link)" }
            $w.l.list insert end $nm
            lappend shown $i
        }
        incr i
    }
}

proc ::lichstudy::setStatus {w text} {
    if {[winfo exists $w.status]} {
        $w.status configure -text $text
        update idletasks
    }
}

proc ::lichstudy::refresh {w} {
    variable studies
    variable token
    if {![winfo exists $w]} { return }
    if {$token eq ""} {
        setStatus $w "Paste your Lichess token and press \"Save\"."
        return
    }
    setStatus $w "Loading your studies..."
    $w configure -cursor watch
    set err [catch {loadStudies} res]
    if {![winfo exists $w]} { return }
    $w configure -cursor ""
    applyFilter $w
    if {$err} {
        setStatus $w $res
    } else {
        setStatus $w "Account $res: [llength $studies] studies. Pick one and press \"Publish\"."
    }
}

proc ::lichstudy::saveToken {w} {
    variable token
    variable dir
    set t [string trim [$w.tok.e get]]
    if {$t ne "" && ![regexp {^[A-Za-z0-9_]+$} $t]} {
        setStatus $w "The token contains invalid characters: copy it again from Lichess."
        return
    }
    set token $t
    writeFile [file join $dir token.txt] $token
    refresh $w
}

proc ::lichstudy::addByLink {w} {
    variable dir
    variable token
    set txt [string trim [$w.add.e get]]
    if {![regexp {lichess\.org/study/([A-Za-z0-9]{8})} $txt -> id]
        && ![regexp {^([A-Za-z0-9]{8})$} $txt -> id]} {
        tk_messageBox -parent $w -icon warning -title "Lichess study" \
            -message "Paste the link of a study, e.g. https://lichess.org/study/AbCd1234"
        return
    }
    if {$token eq ""} {
        setStatus $w "Save your Lichess token first."
        return
    }
    setStatus $w "Checking study $id..."
    if {[catch {api "https://lichess.org/api/study/$id.pgn?clocks=false&comments=false&variations=false"} res]} {
        setStatus $w $res
        return
    }
    lassign $res code body
    if {$code ne "200"} {
        setStatus $w [errorText $code $body]
        return
    }
    set nm "Study $id"
    if {[regexp {\[StudyName "((?:[^"\\]|\\.)*)"\]} $body -> raw]} {
        set nm [string map {\\\" \" \\\\ \\} $raw]
    }
    set nm [string map {"\t" " " "\n" " "} $nm]
    set path [file join $dir extra.txt]
    set data [readFile $path]
    if {![regexp -line "^$id\t" $data]} {
        if {$data ne "" && [string index $data end] ne "\n"} { append data "\n" }
        append data "$id\t$nm\n"
        writeFile $path $data
    }
    $w.add.e delete 0 end
    refresh $w
}

### Dialog ##################################################################

proc ::lichstudy::publish {w} {
    variable studies
    variable shown
    variable busy
    if {$busy} { return }
    set sel [$w.l.list curselection]
    if {$sel eq ""} {
        tk_messageBox -parent $w -icon info -title "Lichess study" \
            -message "Pick a study from the list first."
        return
    }
    lassign [lindex $studies [lindex $shown $sel]] id nm
    doPublish $w $id $nm
}

# Creates a study named $nm and returns its id; raises a readable error.
# The new study holds one empty chapter: it is remembered in "fresh" to be
# deleted after the import (if it cannot be found, it just stays).
proc ::lichstudy::createStudy {nm} {
    variable dir
    variable newVisibility
    variable fresh
    # The name goes through a file so UTF-8 survives on Windows.
    set file [file join $dir "name_[pid].txt"]
    writeFile $file $nm
    set err [catch {api https://lichess.org/api/study \
        --data-urlencode "name@$file" --data-urlencode "visibility=$newVisibility" \
        --data-urlencode computer=everyone --data-urlencode explorer=everyone \
        --data-urlencode cloneable=everyone --data-urlencode shareable=everyone \
        --data-urlencode chat=everyone} res]
    file delete -force $file
    if {$err} { error $res }
    lassign $res code body
    if {$code ne "200" || ![regexp {"id"\s*:\s*"([^"]+)"} $body -> id]} {
        error [errorText $code $body]
    }
    set fresh [list $id ""]
    if {![catch {api "https://lichess.org/api/study/$id.pgn?clocks=false&comments=false&variations=false"} r]
        && [lindex $r 0] eq "200"} {
        set urls [regexp -all -inline {\[ChapterURL "[^"]*/([A-Za-z0-9]{8})"\]} [lindex $r 1]]
        if {[llength $urls] == 2} { set fresh [list $id [lindex $urls 1]] }
    }
    return $id
}

# Creates a new study from the "New study" fields, selects it in the list
# and publishes into it. If the publish fails the study stays selected, so
# pressing "Publish" retries without creating a second one (Lichess allows
# 30 new studies a day).
proc ::lichstudy::createAndPublish {w} {
    variable token
    variable dir
    variable studies
    variable filter
    variable newName
    variable newVisibility
    variable fresh
    variable busy
    if {$busy} { return }
    set nm [string trim $newName]
    if {[string length $nm] < 2 || [string length $nm] > 100} {
        setStatus $w "The study name must be 2 to 100 characters long."
        return
    }
    if {$token eq ""} {
        setStatus $w "Save your Lichess token first."
        return
    }

    set busy 1
    $w.btn.pub state disabled
    $w.new.go state disabled
    $w configure -cursor watch
    setStatus $w "Creating study \"$nm\"..."

    set err [catch {createStudy $nm} id]

    set busy 0
    if {![winfo exists $w]} { return }
    $w configure -cursor ""
    $w.btn.pub state !disabled
    $w.new.go state !disabled
    if {$err} { setStatus $w $id; return }

    set studies [linsert $studies 0 [list $id $nm 0 0]]
    set filter ""
    applyFilter $w
    $w.l.list selection set 0
    set newName ""
    doPublish $w $id $nm
}

# Imports a list of games into study $id, one chapter each.
# Returns {httpCode body}; raises an error on network failure.
proc ::lichstudy::importGames {id gameList} {
    variable orientation
    variable mode
    variable dir
    set file [file join $dir "upload_[pid].pgn"]
    writeFile $file "[join $gameList "\n\n\n"]\n"
    set opts [list --data-urlencode "pgn@$file"]
    if {$orientation ne "auto"} {
        lappend opts --data-urlencode "orientation=$orientation"
    }
    # Normal analysis is Lichess' default: the API wants no "mode" for it.
    if {$mode ne "normal"} {
        lappend opts --data-urlencode "mode=$mode"
    }
    set err [catch {api https://lichess.org/api/study/$id/import-pgn {*}$opts} res]
    file delete -force $file
    if {$err} { error $res }
    return $res
}

# Ends the "busy" state of the dialog. Returns 0 if the dialog is gone.
proc ::lichstudy::idle {w} {
    variable busy
    set busy 0
    if {![winfo exists $w]} { return 0 }
    $w configure -cursor ""
    $w.btn.pub state !disabled
    $w.new.go state !disabled
    return 1
}

# Imports $gameList into study $id. Returns {created problem}; problem is ""
# or a text starting with a blank line.
proc ::lichstudy::importChunked {id gameList} {
    variable fresh
    variable maxChapters
    # A study created by this dialog holds an empty chapter that counts toward
    # the 64-chapter limit. Up to 63 games fit next to it: import all, then
    # delete it. Only 64 games need two steps: the first game, delete the
    # empty chapter, then the other 63.
    set chunks [list $gameList]
    if {$id eq [lindex $fresh 0] && [lindex $fresh 1] ne "" && [llength $gameList] >= $maxChapters} {
        set chunks [list [lrange $gameList 0 0] [lrange $gameList 1 end]]
    }
    set created 0
    foreach chunk $chunks {
        if {![llength $chunk]} { continue }
        if {[catch {importGames $id $chunk} res]} {
            return [list $created "\n\n$res"]
        }
        lassign $res code body
        if {$code ne "200"} {
            return [list $created "\n\n[errorText $code $body]"]
        }
        # {"chapters":[{"id":..,"name":..,...},...],"error":null|"..."}
        set n [regexp -all {"id"\s*:\s*"} $body]
        incr created $n
        if {$n > 0 && $id eq [lindex $fresh 0]} {
            if {[lindex $fresh 1] ne ""} {
                catch {api https://lichess.org/api/study/$id/[lindex $fresh 1] -X DELETE}
            }
            set fresh {}
        }
        if {[regexp {"error"\s*:\s*"((?:[^"\\]|\\.)*)"} $body -> msg]} {
            return [list $created "\n\nLichess reports: [friendly [unescape $msg]]"]
        }
    }
    return [list $created ""]
}

# Modal question when the games do not fit in the study. Returns {} (abort),
# {first} (publish only the first $free) or {split name} (the first $free here,
# the others in a new study called "name").
proc ::lichstudy::askOverflow {w nm free nGames} {
    variable maxChapters
    variable ovfAct
    variable ovfName
    variable ovfMsg
    variable ovfDone
    set rest [expr {$nGames - $free}]
    set d $w.ovf
    destroy $d
    toplevel $d
    wm title $d "Lichess study"
    wm transient $d $w
    wm protocol $d WM_DELETE_WINDOW {set ::lichstudy::ovfDone 0}
    set ovfAct split
    set ovfName [string range "$nm (2)" 0 99]
    set ovfMsg ""
    set ovfDone -1

    if {$free > 0} {
        set txt "\"$nm\" has only $free free chapters out of $maxChapters (the Lichess limit), but you want to publish $nGames games."
    } else {
        set txt "\"$nm\" is full: a Lichess study holds at most $maxChapters chapters."
    }
    ttk::label $d.msg -wraplength 480 -justify left -text "$txt\n\nWhat do you want to do?"
    pack $d.msg -padx 12 -pady {12 6} -anchor w
    if {$free > 0} {
        ttk::radiobutton $d.r1 -variable ::lichstudy::ovfAct -value first \
            -text "Publish only the first $free games here ($rest will not be published)"
        pack $d.r1 -padx 12 -anchor w
        set t2 "Publish the first $free games here and the other $rest in a new study"
    } else {
        set t2 "Publish all $nGames games in a new study"
    }
    ttk::radiobutton $d.r2 -variable ::lichstudy::ovfAct -value split -text $t2
    pack $d.r2 -padx 12 -anchor w
    ttk::frame $d.n
    ttk::label $d.n.l -text "New study name:"
    ttk::entry $d.n.e -textvariable ::lichstudy::ovfName -width 42
    pack $d.n.l $d.n.e -side left -padx {0 6}
    pack $d.n -padx {34 12} -pady 4 -anchor w
    ttk::label $d.err -textvariable ::lichstudy::ovfMsg -foreground red
    pack $d.err -padx 12 -anchor w
    ttk::frame $d.b
    ttk::button $d.b.ok -text "Publish" -command {set ::lichstudy::ovfDone 1}
    ttk::button $d.b.no -text "Abort" -command {set ::lichstudy::ovfDone 0}
    pack $d.b.no $d.b.ok -side right -padx 4
    pack $d.b -padx 12 -pady 12 -fill x

    update
    catch {grab $d}
    while 1 {
        vwait ::lichstudy::ovfDone
        if {$ovfDone == 0} { break }
        if {$ovfAct eq "first"} { break }
        set l [string length [string trim $ovfName]]
        if {$l >= 2 && $l <= 100} { break }
        set ovfMsg "The study name must be 2 to 100 characters long."
        set ovfDone -1
    }
    set act $ovfAct
    set name [string trim $ovfName]
    set done $ovfDone
    destroy $d
    if {!$done} { return {} }
    if {$act eq "first"} { return [list first] }
    return [list split $name]
}

proc ::lichstudy::doPublish {w id nm} {
    variable games
    variable busy
    variable fresh
    if {$busy} { return }
    set nGames [llength $games]

    set busy 1
    $w.btn.pub state disabled
    $w.new.go state disabled
    $w configure -cursor watch
    set what [expr {$nGames == 1 ? "1 game" : "$nGames games"}]

    # Lichess imports games one by one until the study reaches 64 chapters,
    # then stops with "Too many chapters" (HTTP 200: the earlier games are
    # kept). So count the free slots first and let the user decide. A study
    # created by this dialog is known to be empty: skip the check.
    # parts: {studyId name games} for each study to publish into, in order.
    set parts [list [list $id $nm $games]]
    set cut 0
    if {$id ne [lindex $fresh 0]} {
        setStatus $w "Checking free chapters in \"$nm\"..."
        set free [freeChapters $id]
        if {$free >= 0 && $nGames > $free} {
            set ans [askOverflow $w $nm $free $nGames]
            if {![llength $ans]} {
                idle $w
                setStatus $w "Publish cancelled: nothing was published."
                return
            }
            set head [lrange $games 0 [expr {$free - 1}]]
            if {[lindex $ans 0] eq "first"} {
                set parts [list [list $id $nm $head]]
                set cut [expr {$nGames - $free}]
            } else {
                # Create the new study first: if that fails nothing is published.
                set newNm [lindex $ans 1]
                setStatus $w "Creating study \"$newNm\"..."
                if {[catch {createStudy $newNm} newId]} {
                    idle $w
                    setStatus $w $newId
                    tk_messageBox -parent $w -icon error -title "Lichess study" \
                        -message "Could not create the study \"$newNm\": $newId\n\nNothing was published."
                    return
                }
                set parts [list [list $id $nm $head] [list $newId $newNm [lrange $games $free end]]]
            }
        }
    }

    set created 0
    set problem ""
    set report {}
    set openId $id
    foreach part $parts {
        lassign $part pid pnm pgames
        if {![llength $pgames]} { continue }
        setStatus $w "Publishing [llength $pgames] game(s) to \"$pnm\"..."
        lassign [importChunked $pid $pgames] n problem
        incr created $n
        if {$n > 0} {
            lappend report "$n in \"$pnm\""
            set openId $pid
        }
        if {$problem ne ""} {
            set problem "\n\nIn \"$pnm\":$problem"
            break
        }
    }
    if {$cut} { append problem "\n\nGames not published because the study is full: $cut." }

    if {![idle $w]} { return }
    if {$created == 0 && $problem ne ""} {
        setStatus $w [string trim $problem]
        tk_messageBox -parent $w -icon error -title "Lichess study" \
            -message "Nothing was published.$problem"
        return
    }
    set icon [expr {$created == $nGames && $problem eq "" ? "info" : "warning"}]
    set ans [tk_messageBox -parent $w -type yesno -icon $icon -title "Lichess study" \
                 -message "Created $created of $nGames chapters ([join $report {, }]).$problem\n\nOpen the study in your browser?"]
    if {$ans eq "yes"} { openLink "https://lichess.org/study/$openId" }
    if {$created > 0} { destroy $w } else { setStatus $w "No chapter was created.$problem" }
}

proc ::lichstudy::openDialog {gameList} {
    variable token
    variable dir
    variable games
    variable filter
    variable busy

    set games $gameList
    set n [llength $games]
    set filter ""
    set busy 0
    set token [string trim [readFile [file join $dir token.txt]]]

    set w .lichstudy
    if {[winfo exists $w]} { destroy $w }
    toplevel $w
    wm title $w "Publish to Lichess study"

    set what [expr {$n == 1 ? "1 game" : "$n games"}]
    ttk::label $w.head -text "To publish: $what (one chapter per game)"

    ttk::frame $w.tok
    ttk::label $w.tok.l -text "Lichess token:"
    ttk::entry $w.tok.e -width 34 -show "*"
    $w.tok.e insert 0 $token
    ttk::button $w.tok.save -text "Save" -command [list ::lichstudy::saveToken $w]
    ttk::label $w.tok.link -text "Create a token (scopes study:read and study:write)" \
        -foreground blue -cursor hand2
    set url {https://lichess.org/account/oauth/token/create?scopes[]=study:read&scopes[]=study:write&description=scidCommunity+studies}
    bind $w.tok.link <ButtonRelease-1> [list ::lichstudy::openLink $url]
    grid $w.tok.l $w.tok.e $w.tok.save -sticky w -padx 2
    grid x $w.tok.link - -sticky w -padx 2

    ttk::frame $w.find
    ttk::label $w.find.l -text "Search study:"
    ttk::entry $w.find.e -width 30 -textvariable ::lichstudy::filter
    pack $w.find.l $w.find.e -side left -padx 2
    bind $w.find.e <KeyRelease> [list ::lichstudy::applyFilter $w]

    ttk::frame $w.l
    listbox $w.l.list -height 14 -width 60 -exportselection 0 \
        -yscrollcommand [list $w.l.sb set]
    ttk::scrollbar $w.l.sb -command [list $w.l.list yview]
    pack $w.l.sb -side right -fill y
    pack $w.l.list -side left -fill both -expand 1

    # Chapter settings, applied to every chapter created by this import.
    ttk::labelframe $w.opt -text "Chapter settings"
    ttk::label $w.opt.ol -text "Orientation:"
    grid $w.opt.ol -row 0 -column 0 -sticky w -padx 4 -pady 2
    set col 1
    foreach {val txt} {auto Automatic white White black Black} {
        ttk::radiobutton $w.opt.o$val -text $txt -value $val -variable ::lichstudy::orientation
        grid $w.opt.o$val -row 0 -column $col -sticky w -padx 4 -pady 2
        incr col
    }
    ttk::label $w.opt.ml -text "Analysis mode:"
    grid $w.opt.ml -row 1 -column 0 -sticky nw -padx 4 -pady 2
    set row 1
    foreach {val txt} {
        normal   "Normal analysis"
        conceal  "Hide next moves"
        practice "Practice with computer"
        gamebook "Interactive lesson"
    } {
        ttk::radiobutton $w.opt.m$val -text $txt -value $val -variable ::lichstudy::mode
        grid $w.opt.m$val -row $row -column 1 -columnspan 3 -sticky w -padx 4
        incr row
    }

    ttk::labelframe $w.new -text "Or create a new study"
    ttk::label $w.new.nl -text "Name:"
    ttk::entry $w.new.ne -width 30 -textvariable ::lichstudy::newName
    ttk::combobox $w.new.vis -width 9 -state readonly \
        -values {private unlisted public} -textvariable ::lichstudy::newVisibility
    ttk::button $w.new.go -text "Create and publish" \
        -command [list ::lichstudy::createAndPublish $w]
    pack $w.new.nl $w.new.ne $w.new.vis $w.new.go -side left -padx 4 -pady 4

    ttk::frame $w.add
    ttk::label $w.add.l -text "Study you contribute to (link):"
    ttk::entry $w.add.e -width 34
    ttk::button $w.add.b -text "Add" -command [list ::lichstudy::addByLink $w]
    pack $w.add.l $w.add.e $w.add.b -side left -padx 2

    ttk::label $w.status -text "" -wraplength 480 -justify left
    ttk::frame $w.btn
    ttk::button $w.btn.reload -text "Reload list" -command [list ::lichstudy::refresh $w]
    ttk::button $w.btn.pub -text "Publish" -command [list ::lichstudy::publish $w]
    ttk::button $w.btn.cancel -text "Cancel" -command [list destroy $w]
    pack $w.btn.reload -side left -padx 4
    pack $w.btn.cancel $w.btn.pub -side right -padx 4

    pack $w.head -anchor w -padx 8 -pady {8 4}
    pack $w.tok -anchor w -padx 8 -pady 4
    pack $w.find -anchor w -padx 8 -pady 4
    pack $w.l -fill both -expand 1 -padx 8 -pady 4
    pack $w.opt -fill x -padx 8 -pady 4
    pack $w.new -fill x -padx 8 -pady 4
    pack $w.add -anchor w -padx 8 -pady 4
    pack $w.status -anchor w -padx 8 -pady 4
    pack $w.btn -fill x -padx 8 -pady {4 8}
    bind $w <Escape> [list destroy $w]

    after idle [list ::lichstudy::refresh $w]
}

### Hooks ###################################################################

# The Game List builds its right-click menu from scratch every time and then
# shows it with tk_popup. Just before it is shown, add our entry for the
# selected games (the same selection the menu's own commands use).
proc ::lichstudy::onPopup {cmd op} {
    catch {
        set m [lindex $cmd 1]
        if {[string match *.game_menu $m]} {
            set w [string range $m 0 end-[string length .game_menu]]
            if {[info exists ::glistBase($w)] && [winfo exists $w]} {
                if {[info exists ::glistMultiSel($w)] && [llength $::glistMultiSel($w)]} {
                    set sel $::glistMultiSel($w)
                } else {
                    set sel [$w selection]
                }
                set nums [selectionNumbers $sel]
                if {[llength $nums]} {
                    $m add separator
                    $m add command -label "Publish to Lichess study ([llength $nums])..." \
                        -command [list ::lichstudy::publishGames $::glistBase($w) $nums]
                }
            }
        }
    }
}

if {[info commands ::tk_popup] eq ""} { catch {auto_load ::tk_popup} }
catch {trace remove execution ::tk_popup enter ::lichstudy::onPopup}
trace add execution ::tk_popup enter ::lichstudy::onPopup

.menu.tools add separator
.menu.tools add command -label "Publish current game to Lichess study..." \
    -command ::lichstudy::publishCurrent
