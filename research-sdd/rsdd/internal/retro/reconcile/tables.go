package reconcile

import (
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The row-id reader of reconcile-issues.sh (its own awk over the defenced lines): the first cell of every table
// row under a canonical delta section, trimmed at the ends, in file order. The id rule is the grammar's
// TableIDSkip; the header row (the line directly above a separator) is dropped by position.

const cSpace = " \t\n\v\f\r"

// sent stands for an escaped pipe while a row is split (the awk SENT, \001).
const sent = "\x01"

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
)

// lowerASCII is awk tolower in the C locale: only A-Z fold.
func lowerASCII(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + ('a' - 'A')
		}
		return r
	}, s)
}

func isSection(low string) bool {
	for _, re := range reSection {
		if re.MatchString(low) {
			return true
		}
	}
	return false
}

// firstCell is the first cell of a table row: `\|` is an escaped pipe, the cells are split on every other pipe.
// trimmed is the cell cut at both ends, compact the same cell with every blank removed (the id-skip input).
func firstCell(row string) (trimmed, compact string) {
	line := strings.ReplaceAll(row, `\|`, sent)
	line = reLeadPipe.ReplaceAllString(line, "")
	line = reTailPipe.ReplaceAllString(line, "")
	cell := ""
	if line != "" {
		cell = reCellSplit.Split(line, -1)[0]
	}
	cell = strings.ReplaceAll(cell, sent, "|")
	compact = strings.Map(func(r rune) rune {
		if strings.ContainsRune(cSpace, r) { // cSpace is ASCII, so no other rune is removed
			return -1
		}
		return r
	}, cell)
	return strings.Trim(cell, cSpace), compact
}

// tableIDs returns the row ids of the delta tables in lines.
func tableIDs(lines []string) []string {
	var ids []string
	pend := ""
	flush := func() {
		if pend != "" {
			ids = append(ids, pend)
			pend = ""
		}
	}
	inSec := false
	for _, raw := range lines {
		switch {
		case isSection(lowerASCII(raw)):
			flush()
			inSec = true
		case reH2Any.MatchString(raw):
			flush()
			inSec = false
		case inSec && reSepRow.MatchString(raw):
			pend = "" // RECONCILE_ISSUES_HEADER_DROP
		case inSec && strings.HasPrefix(raw, "|"):
			tid, rid := firstCell(raw)
			if retrogrammar.TableIDSkip(rid) {
				continue
			}
			flush()
			pend = tid
		case inSec:
			flush()
		}
	}
	flush()
	return ids
}
