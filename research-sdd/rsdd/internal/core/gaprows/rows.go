package gaprows

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// Kind classifies one table row whose second cell starts with a gap id.
type Kind uint8

const (
	// KindRow is a backlog row: `| high|medium|low|deferred | B<n>-G<m> text | ... | status |` (or a closed-class
	// priority cell with a pending status).
	KindRow Kind = iota + 1
	// KindSkipped is a gap-id row whose priority cell is a closed-class / history marker (an em-dash, `~~strike~~`
	// or a number) and whose status is not pending: out of scope, counted, never unparsed.
	KindSkipped
	// KindUnparsed is a gap-id row the row grammar could not parse (fewer than four cells, or an unknown priority).
	KindUnparsed
)

// UnparsedMax is how many bytes of an unparsed line a Record keeps.
const UnparsedMax = 90

// Record is one classified row.
type Record struct {
	Kind Kind
	Line int // 1-based line of the state file

	// KindRow
	ID      string // B<n>-G<m>
	Block   string // <n>, as written (leading zeros kept)
	Pending bool   // the status (last) cell starts with "pending", ASCII case-insensitive
	Text    string // the row text after the id; tabs read as spaces, `\|` unescaped

	// KindSkipped
	Cell string // the second cell

	// KindUnparsed
	Source string // the first UnparsedMax bytes of the line, a trailing CR removed
}

// Table is the typed reading of one state file.
type Table struct {
	Records []Record
	// Empty is true when the input has no bytes (empty-input). A non-empty input with no gap-id row is a Table whose
	// Records are empty and Empty is false (no-match).
	Empty bool
}

// count returns how many records have the given kind (the tests' tally; gapdrift counts its own).
func (t Table) count(k Kind) int {
	n := 0
	for _, r := range t.Records {
		if r.Kind == k {
			n++
		}
	}
	return n
}

// Parse reads src (gap_rows_parse). It never fails: every line is either a record or not a gap-id row.
func Parse(src string) Table {
	t := Table{Empty: src == ""}
	for r := range gfm.Rows(src, gfm.Options{Shape: gfm.ShapeLeadingPipe}) {
		cells := r.Text()
		n := len(cells)
		if n < 2 || !startsWithGapID(cells[1]) {
			continue
		}
		closed := closedClass(cells[0])
		pending := hasPrefixFold(cells[n-1], "pending")
		switch {
		case closed && !pending:
			t.Records = append(t.Records, Record{Kind: KindSkipped, Line: r.Line, Cell: cells[1]})
		case n < 4 || (!closed && !knownPriority(cells[0])):
			line := r.Source[:min(len(r.Source), UnparsedMax)]
			t.Records = append(t.Records, Record{Kind: KindUnparsed, Line: r.Line, Source: line})
		default:
			id, text := splitID(cells[1])
			t.Records = append(t.Records, Record{Kind: KindRow, Line: r.Line, ID: id, Block: blockOf(id), Pending: pending, Text: text})
		}
	}
	return t
}

// blockOf is the block number of a gap id: the digits between "B" and "-G".
func blockOf(id string) string {
	block, _, _ := strings.Cut(strings.TrimPrefix(id, "B"), "-G")
	return block
}

// startsWithGapID is `^B[0-9]+-G[0-9]+([ \t]|$)`.
func startsWithGapID(s string) bool {
	_, rest, ok := scanID(s)
	return ok && (rest == "" || rest[0] == ' ' || rest[0] == '\t')
}

// scanID reads `B[0-9]+-G[0-9]+` at the start of s.
func scanID(s string) (id, rest string, ok bool) {
	if len(s) == 0 || s[0] != 'B' {
		return "", s, false
	}
	i := digits(s, 1)
	if i == 1 || !strings.HasPrefix(s[i:], "-G") {
		return "", s, false
	}
	j := digits(s, i+2)
	if j == i+2 {
		return "", s, false
	}
	return s[:j], s[j:], true
}

func digits(s string, from int) int {
	i := from
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	return i
}

// splitID cuts a cell into its id and the text after the id and its blanks.
func splitID(cell string) (id, text string) {
	id, rest, _ := scanID(cell)
	text = strings.TrimLeft(rest, " \t")
	return id, strings.ReplaceAll(text, "\t", " ")
}

// closedClass is `^(—|~~|[0-9]+$)`: an em-dash or strike-through start, or an all-digit cell.
func closedClass(pr string) bool {
	if strings.HasPrefix(pr, "—") || strings.HasPrefix(pr, "~~") {
		return true
	}
	return pr != "" && digits(pr, 0) == len(pr)
}

func knownPriority(pr string) bool {
	switch pr {
	case "high", "medium", "low", "deferred":
		return true
	}
	return false
}

// hasPrefixFold reports whether s starts with the lower-case ASCII prefix p, folding ASCII letters only.
func hasPrefixFold(s, p string) bool {
	return strings.HasPrefix(lower(s[:min(len(s), len(p))]), p)
}
