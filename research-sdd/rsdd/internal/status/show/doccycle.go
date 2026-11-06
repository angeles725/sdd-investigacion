package show

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// Port of the document-cycle section of research-sdd-status.sh (kit issue #1152, lines 2385-2455 of the frozen
// script). A corpus whose envelope says `method: document-cycle` is OUTLINE-driven: its ## Gap-backlog is empty on
// purpose, so gap saturation and "read-only-investigable exhausted" say nothing true about it. The default report
// then prints the Outline progress and a document-mode next step instead. Only the exact value `document-cycle`
// counts (`document-cycle-external` keeps the gap-centric report), and only for a single-state-file corpus.
//
// Declared difference from the script: it carried the outline rows between outline_rows and outline_summary as
// tab-separated text read back with `IFS=$'\t' read`, where an empty item cell collapsed the tabs and shifted the
// status into the item. The port keeps the three fields apart, so such a row is read as written.

// docMode is what the document-cycle detection answers (the _doc_mode / _doc_noheading flags).
type docMode int

const (
	docNone      docMode = iota // not a document-cycle corpus
	docOutline                  // method: document-cycle with a ## Outline heading
	docNoHeading                // method: document-cycle without one: the gap-centric verdicts are kept
)

var outlineHeading = regexp.MustCompile(`(?m)^## Outline`)

// docModeOf is the _doc_mode / _doc_noheading detection: the picked state file says `method: document-cycle` and
// the corpus has at most one state file.
func (c *ctx) docModeOf() docMode {
	if m, _ := c.envGet("method"); m != "document-cycle" || len(c.listStates()) > 1 { // DOC-METHOD-EXACT
		return docNone
	}
	if outlineHeading.MatchString(c.stateText()) {
		return docOutline
	}
	return docNoHeading
}

// outlineRow is one data row of the ## Outline table.
type outlineRow struct{ num, item, status string }

// outlineRows is outline_rows: a data row is a pipe row whose first cell is an integer and which has at least
// three cells once the trailing empty ones are dropped; `\|` is cell text. The status is the first word of the
// last non-empty cell, lowercased with bold marks stripped ("drafted (needs review)" -> drafted).
func (c *ctx) outlineRows() []outlineRow {
	var out []outlineRow
	opt := gfm.Options{Shape: gfm.ShapeLeadingPipe, KeepCR: true}
	for r := range gfm.Rows(sectionBody(c.stateText(), "## Outline"), opt) {
		cells := r.Text()
		last := len(cells) - 1
		for last > 0 && cells[last] == "" {
			last--
		}
		if len(cells) == 0 || !isDigits(cells[0]) || last < 2 {
			continue
		}
		st := strings.TrimLeft(strings.ReplaceAll(lowerASCII(cells[last]), "*", ""), " \t")
		if i := strings.IndexAny(st, " \t("); i >= 0 {
			st = st[:i]
		}
		item := strings.TrimSuffix(strings.TrimPrefix(cells[1], "**"), "**")
		out = append(out, outlineRow{cells[0], item, st})
	}
	return out
}

// outlineSummary is the _ol_* state of outline_summary. state keeps three cases apart (kit §7): a heading with no
// data rows, a table holding only the template placeholder (`<topic ...>`, which is not work), and a seeded one.
type outlineSummary struct {
	state                       string // empty | unseeded | seeded
	total, cov, dra, pen, other int
	first                       *outlineRow // the first row that is not covered
}

// summarize is outline_summary. A status outside covered/drafted/pending (plus the done / closed / cubierto / ✅
// spellings hand-written corpora use) is counted as unrecognised and stays OPEN, never silently covered.
func summarize(rows []outlineRow) outlineSummary {
	var s outlineSummary
	for i, r := range rows {
		if strings.HasPrefix(r.item, "<") && strings.HasSuffix(r.item, ">") { // the placeholder
			continue
		}
		s.total++
		switch r.status {
		case "covered", "done", "closed", "cubierto", "✅": // DOC-COVERED-TOKENS
			s.cov++
			continue
		case "drafted":
			s.dra++
		case "pending":
			s.pen++
		default:
			s.other++ // DOC-OTHER-OPEN
		}
		if s.first == nil {
			s.first = &rows[i]
		}
	}
	switch {
	case len(rows) == 0:
		s.state = "empty"
	case s.total == 0:
		s.state = "unseeded"
	default:
		s.state = "seeded"
	}
	return s
}

// outlineLine is outline_line.
func (c *ctx) outlineLine() string {
	const pad = "  outline         : "
	s := summarize(c.outlineRows())
	switch s.state {
	case "empty":
		return pad + "(0 rows — the Outline table is empty)"
	case "unseeded":
		return pad + "(unseeded: only the template placeholder row)"
	}
	line := fmt.Sprintf("%s%d/%d covered · drafted=%d · pending=%d", pad, s.cov, s.total, s.dra, s.pen)
	if s.other > 0 {
		line += fmt.Sprintf(" · unrecognised=%d", s.other)
	}
	return line
}

// outlineNextStep is outline_next_step.
func (c *ctx) outlineNextStep() string {
	s := summarize(c.outlineRows())
	if s.state != "seeded" {
		return "BOOTSTRAP | seed the ## Outline first (document cycle step 1)"
	}
	if s.first != nil {
		return fmt.Sprintf("NEXT | outline #%s | %s", s.first.num, s.first.item)
	}
	return fmt.Sprintf("STOP | outline fully covered (%d/%d)", s.cov, s.total)
}
