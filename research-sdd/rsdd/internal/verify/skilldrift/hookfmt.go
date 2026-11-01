package skilldrift

import (
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The line filters of the hook: what it keeps of `research-sdd-install.sh --verify`, and how the drift lines are shortened so the
// SessionStart budget (kit-session-cost spec, < 8,000 characters across hooks) holds.

var (
	findingRe = regexp.MustCompile(`^verify (harness=[^ ]+ status=degraded|kit status=behind)`)
	driftRe   = regexp.MustCompile(`^verify harness=[^ ]+ status=drift `)
)

const (
	maxFindingLines = 4   // SENTINEL-VERIFY-CAP
	maxFindingBytes = 170 // `cut -c1-170` counts bytes
	driftEntries    = 3   // entries printed per drifted harness
	driftWidth      = 280 // characters per entry
	keptWidth       = 160 // characters of the kept-hand-edit list
)

// lines is `printf '%s\n' "$s" |` as the filters see it.
func lines(s string) []string { return strings.Split(s, "\n") }

// findings is `grep -E '^verify (harness=[^ ]+ status=degraded|kit status=behind)' | cut -c1-170 | head -4`: the degraded and
// behind lines of the --verify output, cut to 170 bytes (cut counts bytes, so a multi-byte character may be split) and capped at
// four. match, absent and current lines are not findings, and neither is a kit `degraded` (SENTINEL-KIT-BEHIND-ONLY).
func findings(vout string) string {
	var keep []string
	for _, l := range lines(vout) {
		if len(keep) == maxFindingLines {
			break
		}
		if findingRe.MatchString(l) {
			if len(l) > maxFindingBytes {
				l = l[:maxFindingBytes]
			}
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}

// clip is the awk function of the same name: at most l characters.
func clip(s string, l int) string {
	if utf8.RuneCountInString(s) <= l {
		return s
	}
	n := 0
	for i := range s {
		if n == l {
			return s[:i]
		}
		n++
	}
	return s
}

// driftReport formats every `verify harness=<h> status=drift ...` line of the --verify output (kit issue #2120). A drift line lists
// every drifted member on ONE line and an annotated entry carries the path to reconcile into. Per harness: a header, then at most
// 3 entries of at most 280 characters (annotated `(extra: ...)` entries first, so a regular-file TARGETS.md is never the one
// dropped), then an explicit `(+N more ...)` line when entries were cut (no silent truncation), then the kept hand-edit list on
// its own line. Only the `drifted=` field is split into entries. The widths count characters, as awk does in a UTF-8 locale.
func driftReport(vout string) string {
	var out []string
	for _, line := range lines(vout) {
		if !driftRe.MatchString(line) {
			continue
		}
		kept := ""
		if k := strings.Index(line, " kept-hand-edit="); k >= 0 {
			kept = line[k+len(" kept-hand-edit="):]
			line = line[:k]
		}
		d := strings.Index(line, " drifted=")
		if d < 0 {
			out = append(out, clip(line, driftWidth)) // SENTINEL-DRIFT-WIDTH
			continue
		}
		out = append(out, line[:d])
		var ents []string
		if rest := line[d+len(" drifted="):]; rest != "" {
			ents = strings.Split(rest, ",")
		}
		shown := 0
		for pass := 1; pass <= 2; pass++ {
			for _, e := range ents {
				annotated := strings.Contains(e, "(extra: ")
				if (pass == 1) != annotated {
					continue
				}
				if shown < driftEntries { // SENTINEL-DRIFT-COUNT
					out = append(out, "  - "+clip(e, driftWidth))
					shown++
				}
			}
		}
		if len(ents) > shown {
			out = append(out, "  (+"+strconv.Itoa(len(ents)-shown)+" more - run research-sdd-install.sh --verify for the full list)") // SENTINEL-DRIFT-MORE
		}
		if kept != "" {
			out = append(out, "  kept-hand-edit: "+clip(kept, keptWidth))
		}
	}
	return strings.Join(out, "\n")
}

// trimNL is the trailing-newline strip of a command substitution.
func trimNL(s string) string { return strings.TrimRight(s, "\n") }
