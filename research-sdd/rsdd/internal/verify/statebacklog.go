package verify

import (
	"fmt"
	"io"
	"regexp"
	"strings"
)

// Ports of the backlog readers of verify-state.sh: _backlog_rows (the awk mirrored from research-sdd-status.sh,
// run with want_closed=0), derive_deferred and the row classifiers built on the rows stream.

var (
	reBacklogHeading = regexp.MustCompile(`^## Gap-backlog( \([^)]+\))?$`)
	reQualifier      = regexp.MustCompile(` *\([^)]*\)$`)
	rePriorityHeader = regexp.MustCompile(`^(priority|pr\.?|p|prioridad)$`)
	reDashes         = regexp.MustCompile(`^-+$`)
)

// backlogRows is the _backlog_rows awk: the open backlog rows as "priority<TAB>gap<TAB>status" lines (status
// lower-cased, one pair of ** removed) in table order, and the INVALID_PRIORITY sentinels in the same stream.
// Its structural warnings go to errw as the awk printed them, once per call.
type backlogStream struct {
	lines   []string // the stdout of the awk, one entry per line (sentinels included)
	invalid []string // the priority values of the INVALID_PRIORITY sentinels, in order
}

func backlogRows(src string, errw io.Writer) backlogStream {
	var (
		out                                 backlogStream
		inBacklog, inData, tblOK, tblWarned bool
		nmWasLast, thisLineNM               bool
		oobCount, expectedCols              int
		prevP                               string
		oobWarn                             = func() {
			fmt.Fprintf(errw, "WARN: %d backlog-format row(s) outside ## Gap-backlog section — move inside a ## Gap-backlog per METHODOLOGY §8b\n", oobCount)
		}
		flushOOB = func() {
			if oobCount > 0 && !nmWasLast {
				oobWarn()
			}
		}
	)
	for _, rec := range recordLines(src) {
		// Rule 1: /^## Gap-backlog( \([^)]+\))?$/
		if reBacklogHeading.MatchString(rec) {
			flushOOB()
			oobCount, nmWasLast = 0, false
			inBacklog, inData = true, false
			expectedCols, tblOK, prevP = 0, false, ""
			continue
		}
		// Rule 2: /^## / && tolower($0) ~ /backlog/ (a near-miss heading)
		if strings.HasPrefix(rec, "## ") && strings.Contains(asciiLower(rec), "backlog") {
			flushOOB()
			oobCount = 0
			thisLineNM = true
			fmt.Fprintf(errw, "WARN: near-miss gap-backlog heading [%s] — expected \"## Gap-backlog\" or \"## Gap-backlog (<label>)\" per METHODOLOGY\n", rec)
		}
		// Rule 3: /^## /
		if strings.HasPrefix(rec, "## ") {
			if !thisLineNM {
				flushOOB()
				oobCount, nmWasLast = 0, false
			}
			nmWasLast = thisLineNM
			thisLineNM = false
			inBacklog, inData = false, false
			expectedCols, tblOK, prevP = 0, false, ""
			continue
		}
		// Rule 4: every other line.
		line := trimBlanks(rec)
		if !strings.Contains(line, "|") {
			prevP = ""
			continue
		}
		a, n := splitPipeCells(line)
		p := asciiLower(cell(a, 1))
		pp := strings.ReplaceAll(prevP, "**", "")
		prevP = p
		if reDashes.MatchString(p) {
			inData = true
			tblOK = rePriorityHeader.MatchString(pp)
			tblWarned = false
			if !inBacklog {
				expectedCols = 0
				if n == 4 || n == 5 {
					expectedCols = n
				}
				continue
			}
			expectedCols = -1
			if n == 4 || n == 5 {
				expectedCols = n
			}
			if expectedCols < 0 {
				fmt.Fprintf(errw, "WARN: backlog table has %d columns (separator: %s) — only 4- or 5-column tables accepted per METHODOLOGY §8b; rows will be skipped\n", n, rec)
			}
			continue
		}
		if strings.HasPrefix(p, "-") {
			continue
		}
		if p == "" || p == "priority" || p == "p" {
			continue
		}
		if p == "deferred" || (len(p) >= 4 && strings.HasPrefix(p, "~~") && strings.HasSuffix(p, "~~")) || strings.HasPrefix(p, "—") {
			continue // closed class: only emitted when want_closed=1, which verify-state never asks for
		}
		base := p
		if loc := reQualifier.FindStringIndex(p); loc != nil {
			base = p[:loc[0]]
		}
		if base != p {
			if base == "high" || base == "medium" || base == "low" || base == "deferred" {
				if inBacklog && inData {
					fmt.Fprintf(errw, "WARN: non-conforming qualifier priority [%s] — strip the qualifier to \"%s\" per METHODOLOGY §8b; row excluded from investigable_open until migrated\n", p, base)
				}
				continue
			}
			if inBacklog && inData {
				fmt.Fprintf(errw, "backlog: unknown priority [%s] in row: %s\n", p, rec)
				out.lines = append(out.lines, "INVALID_PRIORITY\t"+p)
				out.invalid = append(out.invalid, p)
			}
			continue
		}
		if p != "high" && p != "medium" && p != "low" {
			switch {
			case inBacklog && inData:
				fmt.Fprintf(errw, "backlog: unknown priority [%s] in row: %s\n", p, rec)
				out.lines = append(out.lines, "INVALID_PRIORITY\t"+p)
				out.invalid = append(out.invalid, p)
			case nmWasLast && inData && !tblOK:
				if !tblWarned {
					fmt.Fprintln(errw, "WARN: table under a near-miss backlog heading has no Priority header — its rows are NOT read (not a backlog, or add a Priority column)")
					tblWarned = true
				}
			case nmWasLast && inData && tblOK:
				fmt.Fprintf(errw, "WARN: unknown priority [%s] in near-miss backlog row — excluded from counts; not a METHODOLOGY §8b tier: %s\n", p, rec)
			}
			continue
		}
		if !inBacklog && !tblOK {
			if !tblWarned {
				fmt.Fprintln(errw, "WARN: table outside a Gap-backlog section has no Priority header — high/medium/low rows ignored (not a backlog; METHODOLOGY §8b)")
				tblWarned = true
			}
			continue
		}
		if !inBacklog && inData {
			oobCount++
		}
		if expectedCols < 0 {
			continue
		}
		sc := 4
		if expectedCols > 0 {
			sc = expectedCols
		}
		scMsg := "4 or 5"
		if expectedCols > 0 {
			scMsg = fmt.Sprint(sc)
		}
		if n != sc {
			if sc == 5 && n > sc && strings.HasPrefix(asciiLower(cell(a, 5)), "covered") {
				fmt.Fprintf(errw, "WARN: COVERED row has %d cells in 5-col table (pipe in status cell) — review: %s\n", n, rec)
				continue
			}
			if sc == 4 && n > sc && strings.HasPrefix(asciiLower(cell(a, 4)), "covered") {
				fmt.Fprintf(errw, "WARN: COVERED row has %d cells in 4-col table (pipe in status cell) — review: %s\n", n, rec)
				continue
			}
			if inBacklog && inData {
				fmt.Fprintf(errw, "WARN: malformed backlog row (%d cells, expected %s — a cell may contain a pipe): %s\n", n, scMsg, rec)
			}
			continue
		}
		st := asciiLower(cell(a, 5))
		if sc == 4 {
			st = asciiLower(cell(a, 4))
		}
		st = strings.TrimPrefix(st, "**")
		st = strings.TrimSuffix(st, "**")
		out.lines = append(out.lines, p+"\t"+cell(a, 2)+"\t"+st)
	}
	flushOOB() // END: OOB-WARN-EOF
	return out
}

// rowsText is the stream as `printf '%s\n'` prints it ("" for no rows).
func (b backlogStream) rowsText() string { return joinLines(b.lines) }

// each calls f with the gap and status of every stream line, read as `IFS=$'\t' read -r _ gap st` reads them.
func (b backlogStream) each(f func(gap, st string)) {
	for _, l := range b.lines {
		_, gap, st := readTabFields(l)
		f(gap, st)
	}
}

// derivePending is derive_pending_rows: backlog rows whose status leading token is `pending`.
func (b backlogStream) derivePending() int {
	n := 0
	b.each(func(gap, st string) {
		if gap != "" && firstWord(st) == "pending" {
			n++
		}
	})
	return n
}

// deriveInvestigable is derive_investigable: the pending rows whose gap is not an exact blocked-section name.
func (b backlogStream) deriveInvestigable(blocked []string) int {
	n := 0
	b.each(func(gap, st string) {
		if gap == "" || firstWord(st) != "pending" {
			return
		}
		for _, x := range blocked {
			if x != "" && x == gap {
				return
			}
		}
		n++
	})
	return n
}

// deriveRequiresExecution is derive_requires_execution: open rows whose status LEADS with requires-execution.
func (b backlogStream) deriveRequiresExecution() int {
	n := 0
	b.each(func(gap, st string) {
		if gap == "" {
			return
		}
		lead := strings.TrimPrefix(st, "**")
		const tok = "requires-execution"
		if lead != tok {
			rest, ok := strings.CutPrefix(lead, tok)
			if !ok || rest == "" || isLowerAlnum(rest[0]) {
				return
			}
		}
		if strings.Contains(gap, "~~") || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			return
		}
		n++
	})
	return n
}

func isLowerAlnum(c byte) bool { return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' }

// retyped are the gaps of the rows whose leading status token is re-typed / retyped (derive_retyped_in_table,
// _retyped_gaps), struck gaps skipped.
func (b backlogStream) retyped() []string {
	var out []string
	b.each(func(gap, st string) {
		if gap == "" || strings.Contains(gap, "~~") {
			return
		}
		tok := firstWord(stripBold(st))
		if strings.HasPrefix(tok, "re-typed") || strings.HasPrefix(tok, "retyped") {
			out = append(out, gap)
		}
	})
	return out
}

// deriveDeferred is derive_deferred: the DEF-AWK that counts open `deferred` rows of the backlog (not
// byte-compared with research-sdd-status.sh here). Its warnings go to errw.
func deriveDeferred(src string, errw io.Writer) int {
	var (
		inBacklog, tok bool
		ex             int
		prv            string
		n              int
	)
	for _, rec := range recordLines(src) {
		if strings.HasPrefix(rec, "## ") {
			inBacklog = reBacklogHeading.MatchString(rec)
			ex, tok, prv = 0, false, ""
			continue
		}
		line := trimBlanks(rec)
		if !strings.Contains(line, "|") {
			prv = ""
			continue
		}
		a, cnt := splitPipeCells(line)
		p := asciiLower(cell(a, 1))
		pv := strings.ReplaceAll(prv, "**", "")
		prv = p
		if reDashes.MatchString(p) {
			ex = cnt
			tok = rePriorityHeader.MatchString(pv)
			continue
		}
		if p != "deferred" {
			continue
		}
		if !inBacklog && !tok {
			continue
		}
		sc := 4
		if ex > 0 {
			sc = ex
		}
		if sc != 4 && sc != 5 {
			fmt.Fprintf(errw, "WARN: deferred row skipped (table width %d, only 4 or 5 supported): %s\n", sc, rec)
			continue
		}
		if cnt != sc {
			fmt.Fprintf(errw, "WARN: deferred row skipped (%d cells, table width %d — a bare pipe in a cell?): %s\n", cnt, sc, rec)
			continue
		}
		st := asciiLower(cell(a, cnt))
		if strings.Contains(cell(a, 2), "~~") || (sc == 5 && strings.Contains(cell(a, 3), "~~")) || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			continue
		}
		n++
	}
	return n
}
