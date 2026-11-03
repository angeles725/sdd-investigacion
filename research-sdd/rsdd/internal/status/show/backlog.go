package show

import (
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// Ports of backlog_rows and deferred_scan (research-sdd-status.sh, kit #1307 / #2162). Both read the state file
// line by line as awk records and split table rows with internal/core/gfm: every line holding a `|` is a row
// (ShapeAnyPipe), a trailing CR stays in the last cell (KeepCR), cells are trimmed of blanks and a `\|` is a
// literal pipe (Row.Text) — the reader the script's awk programs each re-implemented (READERS.md, backlog :576
// and deferred :520). stdout and stderr of the awk are returned as separate strings.

// anyPipe is the row shape of the backlog and deferred readers.
var anyPipe = gfm.Options{Shape: gfm.ShapeAnyPipe, KeepCR: true}

// tableCells is the text cells of one record, or ok=false when the line holds no `|`.
func tableCells(line string, opt gfm.Options) (cells []string, ok bool) {
	padded, ok := gfm.SplitRow(line, opt)
	if !ok {
		return nil, false
	}
	return gfm.Row{Padded: padded}.Text(), true
}

// cellAt is awk's a[i] (1-based): an index past the cells reads as "".
func cellAt(cells []string, i int) string {
	if i >= 1 && i <= len(cells) {
		return cells[i-1]
	}
	return ""
}

const oobWarn = "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n"

// isClosedDeferred is the closed test shared by the closed-class branch and deferred_scan: `~~` in the first two
// cells (the Gap cell of either 5-column layout) or `~~` / a check mark in the status.
func isClosedDeferred(cells []string, sc int, st string) bool {
	return strings.Contains(cellAt(cells, 2), "~~") || sc == 5 && strings.Contains(cellAt(cells, 3), "~~") ||
		strings.Contains(st, "~~") || strings.Contains(st, "✅")
}

// emDashGapID is the gap-id extraction of the em-dash branch: leading `**`, `~~`, backtick and `[` runs
// dropped, cut at the first blank, `·`, `:`, `—` or `(` (bytes, as in the C locale), trailing `*~`]` dropped.
// It is an id when it is [A-Za-z0-9][A-Za-z0-9._-]* and holds a digit.
func emDashGapID(gap string) bool {
	g := gap
	for {
		t := g
		for _, p := range []string{"**", "~~", "`", "["} {
			t = strings.TrimPrefix(t, p)
		}
		if t == g {
			break
		}
		g = t
	}
	for i := 0; i < len(g); i++ { // the bracket is a byte set under LC_ALL=C: strings.IndexAny would read runes
		if strings.IndexByte(" \t\xc2\xb7:\xe2\x80\x94(", g[i]) >= 0 {
			g = g[:i]
			break
		}
	}
	g = strings.TrimRight(g, "*~`]")
	if g == "" || !(g[0] >= 'A' && g[0] <= 'Z' || g[0] >= 'a' && g[0] <= 'z' || g[0] >= '0' && g[0] <= '9') {
		return false
	}
	return strings.Trim(g, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-") == "" && strings.ContainsAny(g, "0123456789")
}

// statusCell is st = tolower(a[4]) (4 columns) or a[5] (5 columns) with one leading and one trailing `**` removed.
func statusCell(cells []string, sc int) string {
	i := 4
	if sc == 5 {
		i = 5
	}
	st := lowerASCII(cellAt(cells, i))
	return strings.TrimSuffix(strings.TrimPrefix(st, "**"), "**")
}

// backlogRows is backlog_rows [want_closed]: `priority<TAB>gap-key<TAB>status` per backlog row on stdout (plus
// INVALID_PRIORITY and UNCOUNTED lines) and the WARN/diagnostic lines on stderr.
func backlogRows(text string, wantClosed bool) (stdout, stderr string) {
	var out, errb strings.Builder
	var (
		oob                      int
		nmWasLast, thisNM        bool
		inBacklog, inData, tblOK bool
		tblWarned                bool
		expected                 int
		prev                     string
	)
	flush := func() {
		if oob > 0 && !nmWasLast {
			fmt.Fprintf(&errb, oobWarn, oob)
		}
	}
	for _, rec := range splitLines(text) {
		if isGapBacklogHeading(rec) {
			flush()
			oob, nmWasLast = 0, false
			inBacklog, inData, expected, tblOK, prev = true, false, 0, false, ""
			continue
		}
		if strings.HasPrefix(rec, "## ") && strings.Contains(lowerASCII(rec), "backlog") {
			flush()
			oob, thisNM = 0, true
			fmt.Fprintf(&errb, "WARN: near-miss gap-backlog heading [%s] — expected \"## Gap-backlog\" or \"## Gap-backlog (<label>)\" per METHODOLOGY\n", rec)
		}
		if strings.HasPrefix(rec, "## ") {
			if !thisNM {
				flush()
				oob, nmWasLast = 0, false
			}
			nmWasLast, thisNM = thisNM, false
			inBacklog, inData, expected, tblOK, prev = false, false, 0, false, ""
			continue
		}
		isRow := isRowStart(rec)
		unc := func(tier string) {
			if isRow {
				fmt.Fprintf(&out, "UNCOUNTED\t%s\n", tier)
			}
		}
		a, ok := tableCells(rec, anyPipe)
		if !ok {
			prev = ""
			continue
		}
		n := len(a)
		p := lowerASCII(cellAt(a, 1))
		pp := strings.ReplaceAll(prev, "**", "")
		prev = p
		if isAllDashes(p) {
			inData, tblOK, tblWarned = true, isPriorityHeader(pp), false
			if !inBacklog {
				expected = 0
				if n == 4 || n == 5 {
					expected = n
				}
				continue
			}
			expected = -1
			if n == 4 || n == 5 {
				expected = n
			}
			if expected < 0 {
				fmt.Fprintf(&errb, "WARN: backlog table has %d columns (separator: %s) — only 4- or 5-column tables accepted per METHODOLOGY §8b; rows will be skipped\n", n, rec)
			}
			continue
		}
		if strings.HasPrefix(p, "-") || p == "" || p == "priority" || p == "p" {
			continue
		}
		if p == "deferred" || len(p) >= 4 && strings.HasPrefix(p, "~~") && strings.HasSuffix(p, "~~") || strings.HasPrefix(p, "—") {
			if !wantClosed || expected < 0 {
				continue
			}
			if !inBacklog && !tblOK {
				if nmWasLast && inData {
					if !tblWarned {
						errb.WriteString("WARN: table under a near-miss backlog heading has no Priority header — its rows are NOT read (not a backlog, or add a Priority column)\n")
						tblWarned = true
					}
					unc(p)
				}
				continue
			}
			sc := 4
			if expected > 0 {
				sc = expected
			}
			if n != sc {
				if inBacklog && inData {
					fmt.Fprintf(&errb, "WARN: malformed closed-class backlog row (%d cells, expected %d): %s\n", n, sc, rec)
					unc(p)
				}
				continue
			}
			st := statusCell(a, sc)
			tok := ""
			if f := awkFields(st); len(f) > 0 {
				tok = f[0]
			}
			var cp string
			switch {
			case p == "deferred":
				if !isClosedDeferred(a, sc, st) {
					continue
				}
				cp = "deferred"
			case strings.HasPrefix(p, "—"):
				if hasAnyPrefix(tok, "pending", "requires-execution", "open", "queued", "blocked") {
					fmt.Fprintf(&errb, "WARN: em-dash priority on an OPEN row [%s] — METHODOLOGY §8b: em-dash means closed only; row NOT counted (give it a real tier): %s\n", tok, rec)
					continue
				}
				if !emDashGapID(cellAt(a, 2)) {
					fmt.Fprintf(&errb, "WARN: em-dash row whose Gap cell is not a gap id — treated as a note, NOT counted: %s\n", rec)
					continue
				}
				cp = "—"
			default:
				cp = "~~"
			}
			if !inBacklog && inData {
				oob++
			}
			fmt.Fprintf(&out, "%s\t%s\t%s\n", cp, cellAt(a, 2), st)
			continue
		}
		base := stripQualifier(p)
		if base != p {
			if base == "high" || base == "medium" || base == "low" || base == "deferred" {
				if inBacklog && inData {
					fmt.Fprintf(&errb, "WARN: non-conforming qualifier priority [%s] — strip the qualifier to \"%s\" per METHODOLOGY §8b; row excluded from investigable_open until migrated\n", p, base)
				}
				continue
			}
			if inBacklog && inData {
				fmt.Fprintf(&errb, "backlog: unknown priority [%s] in row: %s\n", p, rec)
				fmt.Fprintf(&out, "INVALID_PRIORITY\t%s\n", p)
			}
			continue
		}
		if p != "high" && p != "medium" && p != "low" {
			switch {
			case inBacklog && inData:
				fmt.Fprintf(&errb, "backlog: unknown priority [%s] in row: %s\n", p, rec)
				fmt.Fprintf(&out, "INVALID_PRIORITY\t%s\n", p)
			case nmWasLast && inData && !tblOK:
				if !tblWarned {
					errb.WriteString("WARN: table under a near-miss backlog heading has no Priority header — its rows are NOT read (not a backlog, or add a Priority column)\n")
					tblWarned = true
				}
				if wantClosed {
					unc(p)
				}
			case nmWasLast && inData && tblOK:
				fmt.Fprintf(&errb, "WARN: unknown priority [%s] in near-miss backlog row — excluded from counts; not a METHODOLOGY §8b tier: %s\n", p, rec)
				if wantClosed {
					unc(p)
				}
			}
			continue
		}
		if !inBacklog && !tblOK {
			if !tblWarned {
				errb.WriteString("WARN: table outside a Gap-backlog section has no Priority header — high/medium/low rows ignored (not a backlog; METHODOLOGY §8b)\n")
				tblWarned = true
			}
			if nmWasLast && inData && wantClosed {
				unc(p)
			}
			continue
		}
		if !inBacklog && inData {
			oob++
		}
		if expected < 0 {
			continue
		}
		sc, scMsg := 4, "4 or 5"
		if expected > 0 {
			sc, scMsg = expected, fmt.Sprint(expected)
		}
		if n != sc {
			if sc == 5 && n > sc && strings.HasPrefix(lowerASCII(cellAt(a, 5)), "covered") {
				fmt.Fprintf(&errb, "WARN: COVERED row has %d cells in 5-col table (pipe in status cell) — review: %s\n", n, rec)
				continue
			}
			if sc == 4 && n > sc && strings.HasPrefix(lowerASCII(cellAt(a, 4)), "covered") {
				fmt.Fprintf(&errb, "WARN: COVERED row has %d cells in 4-col table (pipe in status cell) — review: %s\n", n, rec)
				continue
			}
			if inBacklog && inData {
				fmt.Fprintf(&errb, "WARN: malformed backlog row (%d cells, expected %s — a cell may contain a pipe): %s\n", n, scMsg, rec)
				if wantClosed {
					unc(p)
				}
			}
			continue
		}
		fmt.Fprintf(&out, "%s\t%s\t%s\n", p, cellAt(a, 2), statusCell(a, sc))
	}
	flush()
	return out.String(), errb.String()
}

func hasAnyPrefix(s string, prefixes ...string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

// deferredScan is deferred_scan <emit>: the OPEN deferred backlog rows. emit=false prints their count (the
// whole stdout), emit=true one `deferred-open<TAB>gap<TAB>status` line per row. WARN lines go to stderr.
func deferredScan(text string, emit bool) (stdout, stderr string) {
	var out, errb strings.Builder
	var (
		inBacklog, tok bool
		width          int
		prev           string
		n              int
	)
	for _, rec := range splitLines(text) {
		if strings.HasPrefix(rec, "## ") {
			inBacklog, width, tok, prev = isGapBacklogHeading(rec), 0, false, ""
			continue
		}
		a, ok := tableCells(rec, anyPipe)
		if !ok {
			prev = ""
			continue
		}
		cnt := len(a)
		p := lowerASCII(cellAt(a, 1))
		pv := strings.ReplaceAll(prev, "**", "")
		prev = p
		if isAllDashes(p) {
			width, tok = cnt, isPriorityHeader(pv)
			continue
		}
		if p != "deferred" || !inBacklog && !tok {
			continue
		}
		sc := 4
		if width > 0 {
			sc = width
		}
		if sc != 4 && sc != 5 {
			fmt.Fprintf(&errb, "WARN: deferred row skipped (table width %d, only 4 or 5 supported): %s\n", sc, rec)
			continue
		}
		if cnt != sc {
			fmt.Fprintf(&errb, "WARN: deferred row skipped (%d cells, table width %d — a bare pipe in a cell?): %s\n", cnt, sc, rec)
			continue
		}
		st := lowerASCII(cellAt(a, cnt))
		if isClosedDeferred(a, sc, st) {
			continue
		}
		st = strings.TrimPrefix(st, "**")
		if emit {
			fmt.Fprintf(&out, "deferred-open\t%s\t%s\n", cellAt(a, 2), st)
		}
		n++
	}
	if !emit {
		fmt.Fprintf(&out, "%d\n", n)
	}
	return out.String(), errb.String()
}
