package grammar

import (
	"fmt"
	"strings"
)

// Form is the delta form DeltaInfo found (field 1 of retro_grammar_delta_info).
type Form byte

// The five forms, spelled as the bash line spells them.
const (
	FormTable   Form = '1' // table rows in the canonical section (sweep form-1)
	FormEntries Form = '2' // `### … —` entry headings in the canonical section (form-2)
	FormH2Delta Form = '3' // `## Delta <id> —` headings and no canonical section (form-3)
	FormEmpty   Form = 'w' // a canonical heading with nothing countable (WARN-A)
	FormNone    Form = 'n' // no canonical or deprecated heading
)

// DeltaInfo is retro_grammar_delta_info: the delta count of a retro plus what the conformance check needs.
type DeltaInfo struct {
	Found        bool   // a canonical or deprecated heading exists
	Form         Form   // the form Count counts
	Count        int    // data rows (form 1), entries (form 2) or `## Delta` headings (form 3); 0 otherwise
	DeprHeading  string // the first deprecated-alias heading line
	UnrecFound   bool   // an unrecognised delta-intent heading (Rules 1-4) precedes any canonical one
	UnrecData    int    // rows-1 of the first unrecognised `##` section (its header row excluded)
	UnrecHeading string // that first unrecognised heading line
}

// Line renders the bash output: `<found>:<form>:<count>\001<depr>\001<unrec>\001<unrec-data>\001<unrec-heading>`.
func (i DeltaInfo) Line() string {
	return fmt.Sprintf("%d:%c:%d\x01%s\x01%d\x01%d\x01%s\n",
		b2i(i.Found), i.Form, i.Count, i.DeprHeading, b2i(i.UnrecFound), i.UnrecData, i.UnrecHeading)
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// Delta reads the delta section of d. Unrecognised headings and `## Delta` headings are only looked for until
// the first canonical heading (the bash `if (!found)` gate); Rule 4 keeps firing outside any canonical section.
func Delta(d *Doc) DeltaInfo {
	var info DeltaInfo
	inSec, inUnrec := false, false
	rows, entries, h2d, unrecRows := 0, 0, 0, 0
	for _, line := range d.Lines {
		low := lower(line)
		switch {
		case isCanonical(low):
			inSec, inUnrec, info.Found = true, false, true
			if info.DeprHeading == "" && isDeprecated(low) {
				info.DeprHeading = line
			}
		case isH2(line):
			inSec, inUnrec = false, false
			if info.Found {
				continue
			}
			if strings.HasPrefix(low, "## delta ") && strings.Contains(line, "—") {
				h2d++
			}
			if !info.UnrecFound && isUnrecH2(low) {
				info.UnrecFound, info.UnrecHeading, inUnrec = true, line, true
			}
		case !inSec && isH3(line):
			if !info.UnrecFound && isProposalsH3(low) {
				info.UnrecFound, info.UnrecHeading = true, line
			}
		case inSec && isTableRow(line):
			rows++
		case inSec && isH3(line) && strings.Contains(line, "—"):
			entries++
		case inUnrec && isTableRow(line):
			unrecRows++
		}
	}
	info.UnrecData = max(unrecRows-1, 0)
	switch {
	case info.Found && rows > 1:
		info.Form, info.Count = FormTable, rows-1
	case info.Found && entries > 0:
		info.Form, info.Count = FormEntries, entries
	case info.Found:
		info.Form = FormEmpty
	case h2d > 0:
		info.Form, info.Count = FormH2Delta, h2d
	default:
		info.Form = FormNone
	}
	return info
}

// CanonicalHeading is retro_grammar_canonical_heading: the first canonical heading line, false when none.
func CanonicalHeading(d *Doc) (string, bool) {
	for _, line := range d.Lines {
		if isCanonical(lower(line)) {
			return line, true
		}
	}
	return "", false
}

// UnrecHeadings is retro_grammar_unrec_headings: EVERY unrecognised delta-intent heading in file order (Rules 1-3
// `##` headings anywhere, Rule 4 `### Proposals` outside a canonical section). Unlike Delta it does not stop at
// the first canonical heading; for a retro without one, its first entry is DeltaInfo.UnrecHeading.
func UnrecHeadings(d *Doc) []string {
	var out []string
	inSec := false
	for _, line := range d.Lines {
		low := lower(line)
		switch {
		case isCanonical(low):
			inSec = true
		case isH2(line):
			inSec = false
			if isUnrecH2(low) {
				out = append(out, line)
			}
		case !inSec && isH3(line) && isProposalsH3(low):
			out = append(out, line)
		}
	}
	return out
}
