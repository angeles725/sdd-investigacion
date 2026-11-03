package migratebacklogs

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// row is a table line cut by gfm into Padded cells (padding and `\|` kept), plus the bytes around them, so that
// rebuilding an untouched row gives the source back and a rewritten cell keeps its padding.
type row struct {
	prefix string   // the blanks before the first pipe
	cells  []string // gfm Padded cells
	rest   string   // after the last cell: the closing pipe and the blanks behind it
}

// parseRow reads body as a leading-pipe table row.
func parseRow(body string) (row, bool) {
	cells, ok := gfm.SplitRow(body, gfm.Options{})
	if !ok {
		return row{}, false
	}
	p := strings.IndexByte(body, '|')
	return row{prefix: body[:p], cells: cells, rest: body[p+1+len(strings.Join(cells, "|")):]}, true
}

func (r row) String() string { return r.prefix + "|" + strings.Join(r.cells, "|") + r.rest }

// set replaces the text of cell i and keeps its leading and trailing blanks. A cell of blanks only keeps them in
// front of the new text.
func (r *row) set(i int, text string) {
	c := r.cells[i]
	lead := c[:len(c)-len(strings.TrimLeft(c, blanks))]
	trail := ""
	if trimmed := strings.TrimRight(c, blanks); trimmed != "" {
		trail = c[len(trimmed):]
	}
	r.cells[i] = lead + text + trail
}

// isSepFirst is the legacy delimiter test: the FIRST cell alone decides (`^:?-+:?$`).
func isSepFirst(first string) bool {
	first = strings.TrimPrefix(first, ":")
	first = strings.TrimSuffix(first, ":")
	return first != "" && strings.Trim(first, "-") == ""
}

// firstCell is the trimmed first cell, "" for a row without cells.
func (r row) firstCell() string {
	if len(r.cells) == 0 {
		return ""
	}
	return trim(r.cells[0])
}
