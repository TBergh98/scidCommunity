# 30_lichess_study.tcl -- scidCommunity plugin
#
# Publishes games from a scidCommunity database as new chapters of one of
# your Lichess studies. It replaces "export PGN -> open Lichess -> find the
# study -> add chapter -> import PGN" with one dialog.
#
# Where to find it:
#   * Game List window: select one or more games, right click,
#     "Pubblica su studio Lichess (N)...".
#   * Tools menu: "Pubblica partita corrente su studio Lichess..." publishes
#     the game on the board, unsaved changes included.
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
# A study holds at most 64 chapters. Lichess has no endpoint listing the
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
    variable pgn ""         ;# the PGN to publish
    variable nGames 0
    variable filter ""
    variable orientation auto
    variable busy 0
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
        error "curl non trovato: serve per comunicare con Lichess."
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
    if {$err} { error "Errore di rete: [string trim $code]" }
    return [list [string trim $code] $body]
}

proc ::lichstudy::errorText {code body} {
    if {[regexp {"error"\s*:\s*"((?:[^"\\]|\\.)*)"} $body -> msg]} {
        set msg [unescape $msg]
    } else {
        set msg ""
    }
    switch -- $code {
        000 { return "Nessuna risposta da Lichess: controlla la connessione." }
        401 { return "Token non valido o scaduto (401)." }
        403 { return "Permesso negato (403): al token mancano gli scope study:read/study:write, oppure non puoi scrivere in questo studio." }
        404 { return "Studio non trovato (404), oppure è privato e non ne fai parte." }
        429 { return "Troppe richieste a Lichess (429): aspetta un minuto e riprova." }
    }
    if {$msg ne ""} { return "Lichess (HTTP $code): $msg" }
    set body [string trim $body]
    if {[string length $body] > 200} { set body "[string range $body 0 199]..." }
    return "Risposta inattesa da Lichess (HTTP $code). $body"
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
            error "Partita $num non trovata nel database."
        }
        set txt [sc_game pgn -base $base -gameNumber $num {*}[pgnOptions]]
    }
    if {![string match {\[*} [string trimleft $txt]]} {
        error "Impossibile leggere la partita $num: $txt"
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
        tk_messageBox -icon warning -title "Studio Lichess" -message "Il database non è più aperto."
        return
    }
    set n [llength $nums]
    if {$n == 0} { return }
    if {$n > $maxChapters} {
        tk_messageBox -icon warning -title "Studio Lichess" -message \
            "Hai selezionato $n partite, ma uno studio Lichess contiene al massimo $maxChapters capitoli."
        return
    }
    set pgn ""
    if {[catch {
        foreach num $nums { append pgn [gamePgn $base $num] "\n\n\n" }
    } msg]} {
        tk_messageBox -icon warning -title "Studio Lichess" -message $msg
        return
    }
    openDialog $pgn $n
}

proc ::lichstudy::publishCurrent {} {
    if {[sc_game number] == 0 && ![sc_game altered]} {
        tk_messageBox -icon info -title "Studio Lichess" -message \
            "Non c'è nessuna partita sulla scacchiera.\n\nPer pubblicare partite di un database selezionale nella Lista partite e usa il menu del tasto destro."
        return
    }
    if {[catch {cleanGame [sc_game pgn {*}[pgnOptions]]} pgn]} {
        tk_messageBox -icon warning -title "Studio Lichess" -message $pgn
        return
    }
    openDialog "$pgn\n" 1
}

### Studies #################################################################

proc ::lichstudy::loadStudies {} {
    variable studies
    variable dir
    set studies {}

    lassign [api https://lichess.org/api/account] code body
    if {$code ne "200"} { error [errorText $code $body] }
    if {![regexp {"username"\s*:\s*"([^"]+)"} $body -> user]} {
        error "Non riesco a leggere il nome utente dalla risposta di Lichess."
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
            if {$byLink} { append nm "   (aggiunto da link)" }
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
        setStatus $w "Incolla il tuo token Lichess e premi \"Salva\"."
        return
    }
    setStatus $w "Carico i tuoi studi..."
    $w configure -cursor watch
    set err [catch {loadStudies} res]
    if {![winfo exists $w]} { return }
    $w configure -cursor ""
    applyFilter $w
    if {$err} {
        setStatus $w $res
    } else {
        setStatus $w "Account $res: [llength $studies] studi. Scegline uno e premi \"Pubblica\"."
    }
}

proc ::lichstudy::saveToken {w} {
    variable token
    variable dir
    set t [string trim [$w.tok.e get]]
    if {$t ne "" && ![regexp {^[A-Za-z0-9_]+$} $t]} {
        setStatus $w "Il token contiene caratteri non validi: copialo di nuovo da Lichess."
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
        tk_messageBox -parent $w -icon warning -title "Studio Lichess" \
            -message "Incolla il link di uno studio, es. https://lichess.org/study/AbCd1234"
        return
    }
    if {$token eq ""} {
        setStatus $w "Prima salva il tuo token Lichess."
        return
    }
    setStatus $w "Controllo lo studio $id..."
    if {[catch {api "https://lichess.org/api/study/$id.pgn?clocks=false&comments=false&variations=false"} res]} {
        setStatus $w $res
        return
    }
    lassign $res code body
    if {$code ne "200"} {
        setStatus $w [errorText $code $body]
        return
    }
    set nm "Studio $id"
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
    variable pgn
    variable nGames
    variable orientation
    variable busy
    variable dir
    if {$busy} { return }
    set sel [$w.l.list curselection]
    if {$sel eq ""} {
        tk_messageBox -parent $w -icon info -title "Studio Lichess" \
            -message "Scegli prima uno studio dall'elenco."
        return
    }
    lassign [lindex $studies [lindex $shown $sel]] id nm

    set busy 1
    $w.btn.pub state disabled
    $w configure -cursor watch
    setStatus $w "Pubblico $nGames partite in \"$nm\"..."

    set file [file join $dir "upload_[pid].pgn"]
    writeFile $file $pgn
    set opts [list --data-urlencode "pgn@$file"]
    if {$orientation ne "auto"} {
        lappend opts --data-urlencode "orientation=$orientation"
    }
    set err [catch {api https://lichess.org/api/study/$id/import-pgn {*}$opts} res]
    file delete -force $file

    set busy 0
    if {![winfo exists $w]} { return }
    $w configure -cursor ""
    $w.btn.pub state !disabled
    if {$err} { setStatus $w $res; return }
    lassign $res code body
    if {$code ne "200"} { setStatus $w [errorText $code $body]; return }

    # {"chapters":[{"id":..,"name":..,...},...],"error":null|"..."}
    set created [regexp -all {"id"\s*:\s*"} $body]
    set problem ""
    if {[regexp {"error"\s*:\s*"((?:[^"\\]|\\.)*)"} $body -> msg]} {
        set problem "\n\nLichess segnala: [unescape $msg]"
    }
    set icon [expr {$created == $nGames && $problem eq "" ? "info" : "warning"}]
    set ans [tk_messageBox -parent $w -type yesno -icon $icon -title "Studio Lichess" \
                 -message "Creati $created capitoli su $nGames in \"$nm\".$problem\n\nAprire lo studio nel browser?"]
    if {$ans eq "yes"} { openLink "https://lichess.org/study/$id" }
    if {$created > 0} { destroy $w } else { setStatus $w "Nessun capitolo creato.$problem" }
}

proc ::lichstudy::openDialog {pgnText n} {
    variable token
    variable dir
    variable pgn
    variable nGames
    variable filter
    variable busy

    set pgn $pgnText
    set nGames $n
    set filter ""
    set busy 0
    set token [string trim [readFile [file join $dir token.txt]]]

    set w .lichstudy
    if {[winfo exists $w]} { destroy $w }
    toplevel $w
    wm title $w "Pubblica su studio Lichess"

    set what [expr {$n == 1 ? "1 partita" : "$n partite"}]
    ttk::label $w.head -text "Da pubblicare: $what (un capitolo per partita)"

    ttk::frame $w.tok
    ttk::label $w.tok.l -text "Token Lichess:"
    ttk::entry $w.tok.e -width 34 -show "*"
    $w.tok.e insert 0 $token
    ttk::button $w.tok.save -text "Salva" -command [list ::lichstudy::saveToken $w]
    ttk::label $w.tok.link -text "Crea un token (scope study:read e study:write)" \
        -foreground blue -cursor hand2
    set url {https://lichess.org/account/oauth/token/create?scopes[]=study:read&scopes[]=study:write&description=scidCommunity+studies}
    bind $w.tok.link <ButtonRelease-1> [list ::lichstudy::openLink $url]
    grid $w.tok.l $w.tok.e $w.tok.save -sticky w -padx 2
    grid x $w.tok.link - -sticky w -padx 2

    ttk::frame $w.find
    ttk::label $w.find.l -text "Cerca studio:"
    ttk::entry $w.find.e -width 30 -textvariable ::lichstudy::filter
    pack $w.find.l $w.find.e -side left -padx 2
    bind $w.find.e <KeyRelease> [list ::lichstudy::applyFilter $w]

    ttk::frame $w.l
    listbox $w.l.list -height 14 -width 60 -exportselection 0 \
        -yscrollcommand [list $w.l.sb set]
    ttk::scrollbar $w.l.sb -command [list $w.l.list yview]
    pack $w.l.sb -side right -fill y
    pack $w.l.list -side left -fill both -expand 1

    ttk::frame $w.ori
    ttk::label $w.ori.l -text "Orientamento scacchiera:"
    pack $w.ori.l -side left -padx 2
    foreach {val txt} {auto Automatico white Bianco black Nero} {
        ttk::radiobutton $w.ori.$val -text $txt -value $val -variable ::lichstudy::orientation
        pack $w.ori.$val -side left -padx 4
    }

    ttk::frame $w.add
    ttk::label $w.add.l -text "Studio di cui sei collaboratore (link):"
    ttk::entry $w.add.e -width 34
    ttk::button $w.add.b -text "Aggiungi" -command [list ::lichstudy::addByLink $w]
    pack $w.add.l $w.add.e $w.add.b -side left -padx 2

    ttk::label $w.status -text "" -wraplength 480 -justify left
    ttk::frame $w.btn
    ttk::button $w.btn.reload -text "Aggiorna elenco" -command [list ::lichstudy::refresh $w]
    ttk::button $w.btn.pub -text "Pubblica" -command [list ::lichstudy::publish $w]
    ttk::button $w.btn.cancel -text "Annulla" -command [list destroy $w]
    pack $w.btn.reload -side left -padx 4
    pack $w.btn.cancel $w.btn.pub -side right -padx 4

    pack $w.head -anchor w -padx 8 -pady {8 4}
    pack $w.tok -anchor w -padx 8 -pady 4
    pack $w.find -anchor w -padx 8 -pady 4
    pack $w.l -fill both -expand 1 -padx 8 -pady 4
    pack $w.ori -anchor w -padx 8 -pady 4
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
                    $m add command -label "Pubblica su studio Lichess ([llength $nums])..." \
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
.menu.tools add command -label "Pubblica partita corrente su studio Lichess..." \
    -command ::lichstudy::publishCurrent
