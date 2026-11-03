package migratebacklogs

import (
	"regexp"
	"strconv"
	"strings"
)

// The typed reasons of a backlog file that is not rewritten by line.
const (
	reasonUnrecognisedHeading = "unrecognised-backlog-heading"
	reasonMultipleSections    = "multiple-backlog-sections"
	reasonMalformedRow        = "malformed-row"
	reasonNonPriorityTable    = "non-priority-backlog-table"
	reasonEmptySkeleton       = "empty-backlog-skeleton"
	reasonUnsupportedWidth    = "unsupported-table-width"
)

const (
	canonicalHeading = "## Gap-backlog"
	hyphenU2011      = "‑"
)

var (
	reCanonHeading = regexp.MustCompile(`^## Gap-backlog( \([^)]+\))?$`)
	rePriorityHdr  = regexp.MustCompile(`^(priority|pr\.?|p|prioridad)$`)
)

// section is what the first pass learns about one `## ` heading.
type section struct {
	canon bool // the canonical heading
	near  bool // one of the documented near-miss headings (a rename candidate)
	other bool // any other heading with "backlog" in it: never renamed
	prio  bool // the first table row of the section starts with a Priority column
}

// classification is the first pass over a file.
type classification struct {
	sections                                map[int]*section
	anyCanon, anyNear, anyOther, anyPrioTab bool
}

func asciiHeading(h string) string { return strings.ReplaceAll(h, hyphenU2011, "-") }

func nearMiss(h string) bool {
	switch lower(h) {
	case "## gap backlog", "## backlog", "## backlog de gaps":
		return true
	}
	return strings.HasPrefix(h, "## Gap-backlog ")
}

func isPriorityHeader(cell string) bool {
	return rePriorityHdr.MatchString(strings.ReplaceAll(lower(trim(cell)), "**", ""))
}

// classify reads the headings and, per section, the first table row: a priority-led table inside a backlog
// section counts, the same table in `## Campaign queue` does not.
func classify(lines []line) classification {
	c := classification{sections: map[int]*section{}}
	var cur *section
	seen := false
	for i, l := range lines {
		if strings.HasPrefix(l.body, "## ") {
			h := asciiHeading(l.body)
			s := &section{canon: reCanonHeading.MatchString(h)}
			s.near = !s.canon && nearMiss(h)
			s.other = !s.canon && !s.near && strings.Contains(lower(h), "backlog")
			c.sections[i] = s
			cur, seen = s, false
			c.anyCanon = c.anyCanon || s.canon
			c.anyNear = c.anyNear || s.near
			c.anyOther = c.anyOther || s.other
			continue
		}
		if cur == nil || seen {
			continue
		}
		r, ok := parseRow(l.body)
		if !ok {
			continue
		}
		seen = true
		if isPriorityHeader(r.firstCell()) {
			cur.prio = true
			c.anyPrioTab = c.anyPrioTab || cur.near || cur.canon
		}
	}
	return c
}

// manualItem is one line the tool will not touch: why, and where.
type manualItem struct {
	reason string
	line   int // 1-based; 0 for a finding about the file as a whole
}

// migrateBacklog rewrites a RESEARCH-STATE file. skipSkeleton is set for a document-mode focus, which has no
// backlog by design.
func migrateBacklog(lines []line, skipSkeleton bool) ([]line, []manualItem) {
	c := classify(lines)
	var manual []manualItem
	out := make([]line, 0, len(lines)+5)
	var inBacklog, indata, renamed bool
	width := 0
	for i, l := range lines {
		if strings.HasPrefix(l.body, "## ") {
			inBacklog, indata, width = false, false, 0
			s := c.sections[i]
			switch {
			case s.canon:
				inBacklog = true
				l.body = asciiHeading(l.body)
			case s.other:
				manual = append(manual, manualItem{reasonUnrecognisedHeading, i + 1})
			case s.near && s.prio:
				if c.anyCanon || renamed {
					manual = append(manual, manualItem{reasonMultipleSections, i + 1})
				} else {
					l.body, inBacklog, renamed = canonicalHeading, true, true
				}
			}
			out = append(out, l)
			continue
		}
		r, isRow := parseRow(l.body)
		if !isRow {
			// a table ends at the first line that is not a row: the next table starts clean
			indata, width = false, 0
			out = append(out, l)
			continue
		}
		if !inBacklog {
			out = append(out, l)
			continue
		}
		if strings.Contains(l.body, `\|`) {
			manual = append(manual, manualItem{reasonMalformedRow, i + 1})
			out = append(out, l)
			continue
		}
		n := len(r.cells)
		first := strings.ReplaceAll(lower(r.firstCell()), "**", "")
		switch {
		case isSepFirst(first):
			width, indata = -1, true
			if n == 4 || n == 5 {
				width = n
			} else {
				manual = append(manual, manualItem{reasonUnsupportedWidth + " cols=" + strconv.Itoa(n), i + 1})
			}
		case isPriorityHeader(first), width < 0:
		case !indata || n != width:
			if indata {
				manual = append(manual, manualItem{reasonMalformedRow, i + 1})
			}
		default:
			nr, reason := rewriteRow(r, width)
			if reason != "" {
				manual = append(manual, manualItem{reason, i + 1})
			}
			l.body = nr.String()
		}
		out = append(out, l)
	}
	return appendSkeleton(out, c, skipSkeleton, &manual), manual
}

// appendSkeleton closes a file that has no backlog table: the empty canonical section is appended, always
// paired with the manual finding (the rows are the operator's).
func appendSkeleton(out []line, c classification, skip bool, manual *[]manualItem) []line {
	if c.anyCanon || c.anyPrioTab {
		return out
	}
	if c.anyNear {
		*manual = append(*manual, manualItem{reasonNonPriorityTable, 0})
		return out
	}
	if c.anyOther || skip {
		return out
	}
	eol := "\n"
	if n := len(out); n > 0 {
		if out[n-1].eol != "" {
			eol = out[n-1].eol
		} else {
			out[n-1].eol = eol // the last line gains its terminator: the skeleton starts on a line of its own
		}
	}
	for _, b := range []string{"", canonicalHeading, "", "| Priority | Gap | Artifact type / source | Status |", "|---|---|---|---|"} {
		out = append(out, line{body: b, eol: eol})
	}
	*manual = append(*manual, manualItem{reasonEmptySkeleton, 0})
	return out
}
