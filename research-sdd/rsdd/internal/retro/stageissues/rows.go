package stageissues

import (
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The row-table reader: the awk program of stage-retro-issues.sh (the `_rows` block). It reads the DEFENCED
// lines of the retro (fenced code removed), tracks the canonical delta sections and maps each table's header
// cells BY NAME to the title/target/evidence/type/priority roles (kit issue #1260). The first cell of a row is
// its id; the row directly above a separator is the table's header and is dropped by POSITION, which is a known
// gap of the bash that is kept byte for byte (a header-less table loses its first data row).

const cSpace = " \t\n\v\f\r"

var (
	reSection = []*regexp.Regexp{
		regexp.MustCompile(`^## ([0-9]+\. )?proposed kit deltas?([[:space:]]|$)`),
		regexp.MustCompile(`^## proposed delta`),
		regexp.MustCompile(`^## delta proposals`),
		regexp.MustCompile(`^## deltas nuevos`),
		regexp.MustCompile(`^## propuesta de deltas al kit([[:space:]]|$)`),
		regexp.MustCompile(`^## summary of proposed delta`),
		regexp.MustCompile(`^## summary of new deltas`),
		regexp.MustCompile(`^## delta details([[:space:]]|$)`),
	}
	reH2Any     = regexp.MustCompile(`^##[^#]`)
	reSepRow    = regexp.MustCompile(`^\|[-: |]+\|?[[:space:]]*$`)
	reCellSplit = regexp.MustCompilePOSIX(`[[:space:]]*\|[[:space:]]*`)
	reLeadPipe  = regexp.MustCompile(`^\|[[:space:]]*`)
	reTailPipe  = regexp.MustCompile(`[[:space:]]*\|[[:space:]]*$`)
	reColTitle  = regexp.MustCompile(`^(proposed change|proposed delta|proposal|title|delta|gist|change|rule / change|delta propuesto)`)
	reColTarget = regexp.MustCompile(`(target|kit file)`)
	reColEvid   = regexp.MustCompile(`^(evidence|why$)`)
	reColType   = regexp.MustCompile(`^type`)
	reColPrio   = regexp.MustCompile(`^(priority|prioridad)`)
)

// sent stands for an escaped pipe while a row is split (the awk SENT, a control character).
const sent = "\x01"

// escPipes is rg_esc_pipes: every `\|` becomes sent (that backslash dropped, any earlier ones kept).
func escPipes(s string) string { return strings.ReplaceAll(s, `\|`, sent) }

// splitCells is awk split(s, f, /[[:space:]]*\|[[:space:]]*/) followed by the per-cell SENT -> `|` restore.
func splitCells(s string) []string {
	if s == "" {
		return nil
	}
	cells := reCellSplit.Split(s, -1)
	for i, c := range cells {
		cells[i] = strings.ReplaceAll(c, sent, "|")
	}
	return cells
}

func cell(cells []string, k int) string { // awk f[k]: "" past the end (k is 1-based)
	if k >= 1 && k <= len(cells) {
		return cells[k-1]
	}
	return ""
}

// tableRows is the `_rows` awk over the defenced lines.
func tableRows(lines []string) []retrogrammar.Row {
	var out []retrogrammar.Row
	var pend *retrogrammar.Row
	flush := func() {
		if pend != nil {
			out = append(out, *pend)
			pend = nil
		}
	}
	inSec := false
	prev, hasPrev := "", false
	ct, cg, ce, cy, cp := 0, 0, 0, 0, 0
	for _, raw := range lines {
		low := lowerASCII(raw)
		if isSectionHeading(low) {
			flush()
			inSec, prev, hasPrev, ct = true, "", false, 0
			continue
		}
		if reH2Any.MatchString(raw) {
			flush()
			inSec = false
			continue
		}
		if inSec && reSepRow.MatchString(raw) {
			pend = nil // STAGE_RETRO_ISSUES_HEADER_DROP
			if hasPrev {
				ct, cg, ce, cy, cp = headerRoles(prev)
			}
			prev, hasPrev = "", false
			continue
		}
		if inSec && strings.HasPrefix(raw, "|") {
			prev, hasPrev = raw, true
			line := escPipes(raw)
			line = reLeadPipe.ReplaceAllString(line, "")
			line = reTailPipe.ReplaceAllString(line, "")
			f := splitCells(line)
			rid := removeSpace(cell(f, 1))
			if retrogrammar.TableIDSkip(rid) {
				continue
			}
			flush()
			if ct != 0 {
				pend = &retrogrammar.Row{ID: cell(f, 1), Change: cell(f, ct), Target: roleCell(f, cg), Evidence: roleCell(f, ce), Type: roleCell(f, cy), Priority: roleCell(f, cp)}
			} else {
				pend = &retrogrammar.Row{ID: cell(f, 1), Change: cell(f, 2), Target: cell(f, 3), Evidence: cell(f, 4), Type: cell(f, 5), Priority: cell(f, 6)}
			}
			continue
		}
		if inSec {
			flush()
		}
	}
	flush()
	return out
}

func roleCell(f []string, k int) string {
	if k == 0 {
		return ""
	}
	return cell(f, k)
}

func removeSpace(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 128 && strings.ContainsRune(cSpace, r) {
			return -1
		}
		return r
	}, s)
}

func isSectionHeading(low string) bool {
	for _, re := range reSection {
		if re.MatchString(low) {
			return true
		}
	}
	return false
}

// headerRoles reads the header row (the line directly above a separator): the 1-based columns of the title,
// target, evidence, type and priority roles. A header naming no title column returns all zeros, which is the
// positional reading (cells 2..6). Per role a header-name match wins, else the role keeps its POSITIONAL column
// (3..6) when the header has that cell and no other role claimed it.
func headerRoles(prev string) (ct, cg, ce, cy, cp int) {
	hl := escPipes(lowerASCII(prev))
	hl = reLeadPipe.ReplaceAllString(hl, "")
	hl = reTailPipe.ReplaceAllString(hl, "")
	h := splitCells(hl)
	hn := len(h)
	for k := 2; k <= hn; k++ {
		c := h[k-1]
		switch {
		case ct == 0 && reColTitle.MatchString(c):
			ct = k
		case cg == 0 && reColTarget.MatchString(c):
			cg = k
		case ce == 0 && reColEvid.MatchString(c):
			ce = k
		case cy == 0 && reColType.MatchString(c):
			cy = k
		case cp == 0 && reColPrio.MatchString(c):
			cp = k
		}
	}
	if ct == 0 {
		return 0, 0, 0, 0, 0
	}
	used := map[int]bool{ct: true}
	for _, k := range []int{cg, ce, cy, cp} {
		if k != 0 {
			used[k] = true
		}
	}
	if cg == 0 && 3 <= hn && !used[3] {
		cg, used[3] = 3, true
	}
	if ce == 0 && 4 <= hn && !used[4] {
		ce, used[4] = 4, true
	}
	if cy == 0 && 5 <= hn && !used[5] {
		cy, used[5] = 5, true
	}
	if cp == 0 && 6 <= hn && !used[6] {
		cp, used[6] = 6, true
	}
	return ct, cg, ce, cy, cp
}

// ---- cell mapping helpers of the main loop

// mapType is map_type: docs | bug | feature.
func mapType(cell string) string {
	switch stripSpaceLower(cell) {
	case "doc", "docs", "documentation", "doc-fix", "docfix":
		return "docs"
	case "bug", "fix", "bugfix", "defect", "regression":
		return "bug"
	}
	return "feature"
}

// mapPriority is map_priority: high | medium | low, "" omits the label.
func mapPriority(cell string) string {
	switch p := stripSpaceLower(cell); p {
	case "high", "medium", "low":
		return p
	}
	return ""
}

// stripSpaceLower is `tr 'A-Z' 'a-z' | tr -d '[:space:]'`.
func stripSpaceLower(s string) string { return removeSpace(lowerASCII(s)) }

var reWrongKit = regexp.MustCompilePOSIX(`[-a-zA-Z0-9]+-kit[:/]`)

// isWrongKit is is_wrong_kit: the Target cell names another kit (`niagara-kit:...`). grep -i, so the case is folded.
func isWrongKit(targetCell string) bool { return reWrongKit.MatchString(lowerASCII(targetCell)) }

var reBoldLead = regexp.MustCompile(`^\*\*([^*]+)\*\*.*`)

// stripMDBold is strip_md_bold: a cell opening with a bold lead-in (**phrase**) yields just the phrase (the
// author's one-line summary); otherwise a leading and a trailing ** are stripped.
func stripMDBold(s string) string {
	if m := reBoldLead.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	s = strings.TrimPrefix(s, "**")
	return strings.TrimSuffix(s, "**")
}

// trimSpace is sed 's/^[[:space:]]*//;s/[[:space:]]*$//'.
func trimSpace(s string) string { return strings.Trim(s, cSpace) }
