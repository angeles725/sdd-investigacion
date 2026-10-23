// Package gfm is the kit's single GFM pipe-table reader. It replaces the hand-copied awk and bash readers that
// each re-implemented the escaped-pipe rule (see READERS.md for the reader-by-reader map and the places where
// those readers disagree with each other).
//
// THE RULE (verified against GitHub's renderer, kit PR #2147): ANY `\|` inside a table cell is an escaped pipe,
// however many backslashes precede it. `| x\\| y | z |` is ONE cell `x\| y` plus `z`; `| m\\\| n |` is ONE cell.
// The pipe is the escaped character; every other backslash is ordinary text.
//
// A cell has three views, because the kit readers disagree on what they hand to their callers:
//   - Padded: the bytes between two separators, untouched (padding and `\|` kept). migrate-backlogs.sh rewrites
//     rows from these bytes.
//   - Raw: Padded trimmed of blanks (space, tab); `\|` kept. Round-trips through Unescape/Escape.
//   - Text: Raw with each `\|` turned back into `|`. Every other reader uses this.
package gfm

import (
	"iter"
	"strings"
)

// Shape selects which lines count as table rows.
type Shape int

const (
	// ShapeLeadingPipe: a row starts with optional blanks and then `|` (gap-rows.sh, focus-partition-audit.sh,
	// migrate-backlogs.sh, verify-sources.sh). This is the default and the right choice for prose-bearing files
	// such as TARGETS.md, whose detail sections must never be read as rows.
	ShapeLeadingPipe Shape = iota
	// ShapeAnyPipe: any line containing a `|` (even an escaped one) is a row (verify-state.sh and the backlog,
	// deferred, contradictions, iteration and FOCUSES readers of research-sdd-status.sh).
	ShapeAnyPipe
)

// Options selects reader behaviour where the kit readers differ.
type Options struct {
	Shape Shape
	// KeepCR leaves a trailing carriage return in place. gap-rows.sh strips it; every other reader keeps it,
	// which turns `| a |\r` into a trailing extra cell. The default (false) follows gap-rows.sh.
	KeepCR bool
}

// Row is one table line. Line is 1-based.
type Row struct {
	Line   int
	Source string   // the source line (a trailing CR removed unless Options.KeepCR)
	Padded []string // see the package comment
	Sep    bool     // the cells form a GFM delimiter row (`---`, `:-:`, ...)
}

// Len is the number of cells. A bare `|` or `||` is a row with zero cells (the awk `split("", a, "|")` result).
func (r Row) Len() int { return len(r.Padded) }

// Raw returns the cells trimmed of blanks with `\|` kept. The result is never nil.
func (r Row) Raw() []string {
	out := make([]string, len(r.Padded))
	for i, c := range r.Padded {
		out[i] = trimBlanks(c)
	}
	return out
}

// Text returns the cells trimmed of blanks with each `\|` turned into `|`. The result is never nil.
func (r Row) Text() []string {
	out := make([]string, len(r.Padded))
	for i, c := range r.Padded {
		out[i] = Unescape(trimBlanks(c))
	}
	return out
}

func trimBlanks(s string) string { return strings.Trim(s, " \t") }

// Unescape turns each `\|` into `|`. Other backslashes are untouched.
func Unescape(s string) string {
	if !strings.Contains(s, `\|`) {
		return s
	}
	return strings.ReplaceAll(s, `\|`, "|")
}

// Escape turns each `|` into `\|`. Escape(Unescape(x)) == x for any cell x produced by SplitRow.
func Escape(s string) string {
	if !strings.Contains(s, "|") {
		return s
	}
	return strings.ReplaceAll(s, "|", `\|`)
}

// IsSeparator reports whether every cell is a GFM delimiter cell (`^:?-+:?$`). Zero cells is NOT a separator
// (the awk readers treat it as one by vacuous truth; see READERS.md).
func IsSeparator(cells []string) bool {
	if len(cells) == 0 {
		return false
	}
	for _, c := range cells {
		c = trimBlanks(c)
		c = strings.TrimPrefix(c, ":")
		c = strings.TrimSuffix(c, ":")
		if c == "" || strings.Trim(c, "-") != "" {
			return false
		}
	}
	return true
}

// SplitRow splits one line into Padded cells. ok is false when the line is not a row under opt.Shape.
// It never panics and never reads outside line.
func SplitRow(line string, opt Options) (cells []string, ok bool) {
	if !opt.KeepCR {
		line = strings.TrimSuffix(line, "\r")
	}
	s := trimBlanks(line)
	switch opt.Shape {
	case ShapeAnyPipe:
		if !strings.Contains(s, "|") {
			return nil, false
		}
	default:
		if !strings.HasPrefix(s, "|") {
			return nil, false
		}
	}
	s = strings.TrimPrefix(s, "|")
	// One forward pass: a `\` directly before `|` escapes it (left to right, so `\\|` is `\` + escaped pipe).
	bare, closing := 0, false
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '\\' && i+1 < len(s) && s[i+1] == '|':
			i++
		case s[i] == '|':
			bare++
			closing = i == len(s)-1
		}
	}
	if closing {
		s = s[:len(s)-1]
		bare--
	}
	if s == "" {
		return []string{}, true
	}
	cells = make([]string, 0, bare+1)
	start := 0
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '\\' && i+1 < len(s) && s[i+1] == '|':
			i++
		case s[i] == '|':
			cells = append(cells, s[start:i])
			start = i + 1
		}
	}
	return append(cells, s[start:]), true
}

// Rows yields every table row of src in order, with 1-based line numbers. Lines are split on "\n"; a final
// line without a trailing newline is a line like any other.
func Rows(src string, opt Options) iter.Seq[Row] {
	return func(yield func(Row) bool) {
		line := 0
		for pos := 0; pos < len(src); {
			end := strings.IndexByte(src[pos:], '\n')
			var text string
			if end < 0 {
				text, pos = src[pos:], len(src)
			} else {
				text, pos = src[pos:pos+end], pos+end+1
			}
			line++
			cells, ok := SplitRow(text, opt)
			if !ok {
				continue
			}
			if !opt.KeepCR {
				text = strings.TrimSuffix(text, "\r")
			}
			r := Row{Line: line, Source: text, Padded: cells}
			r.Sep = IsSeparator(r.Raw())
			if !yield(r) {
				return
			}
		}
	}
}
