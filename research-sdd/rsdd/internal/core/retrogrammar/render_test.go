package retrogrammar

import (
	"errors"
	"strconv"
	"strings"
)

// bashOut is one oracle result: the bytes on both channels and the return code.
type bashOut struct {
	stdout, stderr string
	rc             int
}

// rcOf is the shell return code of a Go predicate.
func rcOf(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

// joinLines renders records the way awk prints them: each one "\n"-terminated.
func joinLines(xs []string) string {
	var b strings.Builder
	for _, x := range xs {
		b.WriteString(x)
		b.WriteByte('\n')
	}
	return b.String()
}

// fileModes maps a driver file mode to the Go rendering of the same call. Every mode reads through Read, so an
// absent or unreadable path takes the typed-error branch the mode documents.
var fileModes = map[string]func(path string) bashOut{
	"defenced": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(d.Lines), stderr: d.FenceWarning()}
	},
	// delta_info: bash prints a zero line for an absent file (rc 0, the silent zero Go reports as ErrAbsentInput)
	// and a typed stderr line plus the zero line, rc 1, for an unreadable one.
	"delta": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrAbsentInput):
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line()}
		case err != nil:
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line(), rc: 1,
				stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		}
		return bashOut{stdout: Delta(d).Line(), stderr: d.FenceWarning()}
	},
	"canon": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		h, ok := CanonicalHeading(d)
		if !ok {
			return bashOut{}
		}
		return bashOut{stdout: h + "\n"}
	},
	"unrec":     readThen(func(d *Doc) []string { return UnrecHeadings(d) }),
	"entryrows": readThen(func(d *Doc) []string { return rowLines(EntryRows(d)) }),
	// entry_ids prints nothing for no entries; its read failure is entry_rows' rc 1.
	"entryids": readThen(EntryIDs),
	// entry_warn always returns 0; on an unreadable file only its delta_info call speaks.
	"entrywarn": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrUnreadable):
			return bashOut{stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		case err != nil:
			return bashOut{}
		}
		return bashOut{stdout: EntryWarn(d)}
	},
}

// awkCannotOpen stands for gawk's own fatal line (it names the awk program line, so it is not pinned byte for
// byte): retro_grammar_has_honesty does not guard readability, so an unreadable file is an untyped rc 2.
const awkCannotOpen = "<awk: fatal: cannot open file>"

func init() {
	fileModes["honesty"] = func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrUnreadable):
			return bashOut{rc: 2, stderr: awkCannotOpen}
		case err != nil:
			return bashOut{rc: 1}
		}
		return bashOut{rc: rcOf(HasHonesty(d))}
	}
	fileModes["rowtitles"] = func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		var b strings.Builder
		for _, r := range RowTitles(d) {
			b.WriteString(r.Line())
		}
		return bashOut{stdout: b.String()}
	}
	// The marker readers print nothing (or return 1) for an absent path and, silently, for an unreadable one:
	// the bash reader discards its read error (finding F3 in doc.go).
	fileModes["rstatus"] = markerMode(func(d *Doc) bashOut { return lineOut(ReviewStatus(d)) }, bashOut{})
	fileModes["mscope"] = markerMode(func(d *Doc) bashOut { return lineOut(MarkerScopeLine(d)) }, bashOut{})
	fileModes["excluded"] = markerMode(func(d *Doc) bashOut { return bashOut{rc: rcOf(IsExcluded(d))} }, bashOut{rc: 1})
	fileModes["waived"] = markerMode(func(d *Doc) bashOut { return bashOut{rc: rcOf(IsWaived(d))} }, bashOut{rc: 1})
	fileModes["mline"] = markerMode(func(d *Doc) bashOut { return lineOut(markerLine(d)) }, bashOut{})
	fileModes["oos"] = markerMode(func(d *Doc) bashOut { return bashOut{rc: rcOf(MarkerOutOfScope(d))} }, bashOut{rc: 1})
	fileModes["bare"] = markerMode(func(d *Doc) bashOut { return bashOut{rc: rcOf(HasBareMarker(d))} }, bashOut{rc: 1})
	fileModes["altrows"] = readThen(func(d *Doc) []string { return rowLines(AltEntryRows(d)) })
	fileModes["altheads"] = readThen(AltHeads)
}

// tokenModes maps a driver token mode to the Go verdict, rendered the way the driver frames it.
var tokenModes = map[string]func(tok string) bashOut{
	"deltaid": func(tok string) bashOut { return bashOut{stdout: strconv.Itoa(b2i(DeltaID(tok))) + "\n"} },
	"idskip":  func(tok string) bashOut { return bashOut{stdout: strconv.Itoa(b2i(TableIDSkip(tok))) + "\n"} },
	"idsafe":  func(tok string) bashOut { return bashOut{rc: rcOf(IDSignatureSafe(tok))} },
}

// markerMode renders a marker reader: failed reads answer onFail whatever the failure.
func markerMode(f func(*Doc) bashOut, onFail bashOut) func(string) bashOut {
	return func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return onFail
		}
		return f(d)
	}
}

// lineOut renders a reader that prints one line or nothing.
func lineOut(s string) bashOut {
	if s == "" {
		return bashOut{}
	}
	return bashOut{stdout: s + "\n"}
}

// rowLines renders rows as their bash records, without the trailing newline joinLines adds back.
func rowLines(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = strings.TrimSuffix(r.Line(), "\n")
	}
	return out
}

// readThen renders a mode that prints one line per result and returns 1, silently, on a failed read.
func readThen(f func(*Doc) []string) func(string) bashOut {
	return func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(f(d))}
	}
}

// idsOut renders an id list the way the bash helpers print it.
func idsOut(ids []string, err error) bashOut {
	if err != nil {
		return bashOut{rc: -1, stderr: err.Error()}
	}
	return bashOut{stdout: joinLines(ids)}
}

// lineModes maps a driver line mode to the Go rendering of the same call on one marker line.
var lineModes = map[string]func(line string) bashOut{
	"sfml":    func(l string) bashOut { return lineOut(StatusFromMarkerLine(l)) },
	"partial": func(l string) bashOut { return bashOut{rc: rcOf(MarkerIsPartial(l))} },
	// shipped_raw prints its (possibly empty) list line whenever the keyword matched.
	"shraw": func(l string) bashOut {
		if l == "" || grepO(l, reShippedList) == "" {
			return bashOut{}
		}
		return bashOut{stdout: ShippedRaw(l) + "\n"}
	},
	"shids": func(l string) bashOut { return idsOut(ShippedIDs(l)) },
	"dism": func(l string) bashOut {
		ids, malformed, err := dismissedIDs(l)
		if malformed {
			return bashOut{rc: 3}
		}
		return idsOut(ids, err)
	},
}
