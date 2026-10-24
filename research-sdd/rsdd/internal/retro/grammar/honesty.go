package grammar

import (
	"regexp"
	"strings"
)

// retro_grammar_has_honesty (§912): does the retro carry a §18 honesty line in a PURE accepted location? It reads
// the RAW lines (a fenced block in the canonical section is impure by construction, so it is not defenced).
//   A. Every non-blank, non-table body line of the canonical section is an honesty line. The LEADING BLOCKQUOTE
//      block right after the heading is exempt template scaffold unless one of its lines carries a structural
//      marker (isDirtyMarker); then all of it counts as body. A header+separator table with no data row is an
//      empty body; any data row fails.
//   B. `## [N. ]Honest verdict` counts only when the canonical section is absent or its body is empty.
//   C. An honesty line is one of the four exact §18 variants after stripping list/quote/emphasis markers.
//   D. Veto anywhere: a non-canonical `## Proposed|Delta|Deltas` heading, a `## <letter><digits>` heading, a
//      `### Proposed|Delta|Deltas` heading or a `#`/`###` letter+digit heading, or `# <digit>` (outside the section).

var (
	reHonestVerdict = regexp.MustCompile(`^## ([0-9]+\. )?honest verdict([[:space:]]|$)`)
	reVetoH2Word    = regexp.MustCompile(`^## (proposed|delta|deltas)([[:space:]]|$)`)
	reVetoH2ID      = regexp.MustCompile(`^## [A-Za-z][0-9]+([^a-zA-Z0-9]|$)`) // RSDD_H2_VETO
	reVetoH3Word    = regexp.MustCompile(`^###[[:space:]]+(proposed|delta|deltas)([[:space:]]|$)`)
	reVetoHashID    = regexp.MustCompile(`^(#|###)[[:space:]]+[A-Za-z][0-9]|^#[[:space:]]+[0-9]`)
	reMarkerLead    = regexp.MustCompile(`^[-*+>][[:space:]]*`)
	reDirty         = regexp.MustCompile(`^([-*+][[:space:]]|#{1,6}[[:space:]]|\||[0-9]+[.)]([[:space:]]|$)|[a-zA-Z][)]([[:space:]]|$)|•|\[[ xX]\]([[:space:]]|$))`)
	honestyVariants = map[string]bool{
		"no new deltas; the kit already covers this run.":  true,
		"no new deltas; nothing to add.":                   true,
		"no new deltas — the kit already covers this run.": true,
		"no new deltas — nothing to add.":                  true,
	}
)

// honestyScan is the per-file state of the purity check.
type honestyScan struct {
	inCanon, inHV, canonFound, veto bool
	bodyCount, bodyPipe             int
	bodyOK, bodyStarted             bool
	hvHonesty, leadDirty            bool
	lead                            []string
}

// HasHonesty is retro_grammar_has_honesty on d.Raw.
func HasHonesty(d *Doc) bool {
	s := &honestyScan{bodyOK: true}
	for _, line := range d.Raw {
		s.line(line)
	}
	if s.veto {
		return false
	}
	if s.canonFound && !s.bodyStarted && s.leadDirty { // RSDD_LEAD_BLOCK_END_FLUSH_ANCHOR
		s.countLead()
	}
	if !s.canonFound {
		return s.hvHonesty
	}
	if s.bodyPipe > 1 { // a data row below the header
		return false
	}
	if s.bodyCount > 0 {
		return s.bodyOK
	}
	return s.hvHonesty
}

func (s *honestyScan) line(line string) {
	low := lower(line)
	switch {
	case isH2(line):
		if isCanonical(low) {
			s.inCanon, s.inHV, s.canonFound = true, false, true
			return
		}
		s.inCanon, s.inHV = false, reHonestVerdict.MatchString(low)
		if reVetoH2Word.MatchString(low) || reVetoH2ID.MatchString(line) {
			s.veto = true
		}
	case !s.inCanon && strings.HasPrefix(line, "#"):
		if reVetoH3Word.MatchString(low) || reVetoHashID.MatchString(line) {
			s.veto = true
		}
	case trimLeftSpace(line) == "":
	case s.inCanon:
		s.body(line)
	case s.inHV && isHonesty(line):
		s.hvHonesty = true
	}
}

// body checks one non-blank line of the canonical section.
func (s *honestyScan) body(line string) {
	if !s.bodyStarted {
		if strings.HasPrefix(line, ">") && !isHonesty(line) { // the lead block: buffered, tainted by a marker
			s.leadDirty = s.leadDirty || isDirtyMarker(line) // RSDD_LEAD_DIRTY_SET
			s.lead = append(s.lead, line)
			return
		}
		s.bodyStarted = true
		if s.leadDirty {
			s.countLead()
		}
	}
	if strings.HasPrefix(line, "|") {
		if isTableRow(line) {
			s.bodyPipe++
		}
		return
	}
	s.count(line)
}

func (s *honestyScan) countLead() {
	for _, l := range s.lead {
		s.count(l)
	}
}

func (s *honestyScan) count(line string) {
	s.bodyCount++
	s.bodyOK = s.bodyOK && isHonesty(line)
}

// isHonesty is is_honesty: one of the four exact §18 variants once markers, case and trailing emphasis are gone.
func isHonesty(raw string) bool {
	l := trimRightSpace(lower(stripMarkers(raw)))
	l = strings.TrimSuffix(l, "**")
	l = strings.TrimSuffix(l, "__")
	l = strings.TrimSuffix(l, "_")
	return honestyVariants[trimRightSpace(l)]
}

// stripMarkers is strip_markers: leading blanks, then list/quote markers, `**`, `__` and a single `_` (not `__`)
// repeatedly, until nothing changes.
func stripMarkers(s string) string {
	s = trimLeftSpace(s)
	for prev := ""; s != prev && s != ""; {
		prev = s
		s = trimLeftSpace(reMarkerLead.ReplaceAllString(s, ""))
		s = trimLeftSpace(strings.TrimPrefix(s, "**"))
		s = trimLeftSpace(strings.TrimPrefix(s, "__"))
		if len(s) > 1 && s[0] == '_' && s[1] != '_' {
			s = trimLeftSpace(s[1:])
		}
	}
	return s
}

// isDirtyMarker is is_dirty_marker: a lead-block line that, with every `>` level and NBSP gone, starts with a
// bullet, a 1-6 `#` heading, a table pipe, an ordered or `a)` list item, a `•` or a checkbox. Em and en dashes
// are deliberately not markers (template prose wraps onto `> — …` lines).
func isDirtyMarker(raw string) bool {
	r := strings.ReplaceAll(raw, " ", " ")
	for strings.HasPrefix(r, ">") {
		r = trimLeftSpace(r[1:])
	}
	return reDirty.MatchString(trimLeftSpace(r))
}
