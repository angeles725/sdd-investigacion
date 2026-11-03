package show

import (
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// Port of _read_focuses_tok_uncached / _read_focuses_tok_into (research-sdd-status.sh, METHODOLOGY §16): the
// validated leading status token of one focus in FOCUSES.md.

// focusTokens is the closed vocabulary of METHODOLOGY §16. closed is not a token.
var focusTokens = []string{"active", "paused", "stopped", "planned", "bootstrapping", "reopened", "document"}

// focusCells splits one FOCUSES.md line the way that awk does: on the UNTRIMMED line, so an indented row keeps its
// leading pipe (its first cell is the blanks before it and every column moves right by one) and a row with
// trailing blanks keeps its closing pipe (a phantom empty last cell) — READERS.md, quirk 7. gfm.SplitRow trims
// both ends first; the two quirks are restored by moving the blanks into a cell: a line that starts with a blank
// gets a pipe in front, one that ends with a blank gets one behind.
func focusCells(line string) []string {
	l := line
	if strings.HasPrefix(l, " ") || strings.HasPrefix(l, "\t") {
		l = "|" + l
	}
	if strings.HasSuffix(l, " ") || strings.HasSuffix(l, "\t") {
		l += "|"
	}
	cells, _ := tableCells(l, anyPipe)
	return cells
}

// stripMarkup is strip_markup: a [text](url) link reduced to its text, a backtick wrap removed, one leading `**`
// and the first further `**` removed.
func stripMarkup(s string) string {
	r := s
	if strings.HasPrefix(r, "[") {
		if i := strings.IndexByte(r, ']'); i > 0 && strings.HasPrefix(r[i:], "](") && strings.HasSuffix(r, ")") && !strings.Contains(r[i+2:len(r)-1], ")") {
			r = r[1:i]
		}
	}
	if len(r) >= 2 && r[0] == '`' && r[len(r)-1] == '`' && !strings.Contains(r[1:len(r)-1], "`") {
		r = r[1 : len(r)-1]
	}
	r = strings.TrimPrefix(r, "**")
	return strings.Replace(r, "**", "", 1)
}

// leadTok is lead_tok: the markup-stripped cell cut at its first whitespace, lower-cased.
func leadTok(s string) string {
	t := stripMarkup(s)
	if i := strings.IndexAny(t, cSpace); i >= 0 {
		t = t[:i]
	}
	return lowerASCII(t)
}

// focusTok is _read_focuses_tok_uncached for the FOCUSES.md text: the token ("" when absent or non-conforming)
// and the WARN lines. sbase is the state-file basename.
func focusTok(text, sbase string) (tok, warn string) {
	fslug := strings.TrimSuffix(strings.TrimPrefix(sbase, "RESEARCH-STATE-"), ".md")
	var w strings.Builder
	var fcol, scol, sfcol int
	hdone, found := false, false
	for _, line := range splitLines(text) {
		if !strings.Contains(line, "|") {
			continue
		}
		a := focusCells(line)
		n := len(a)
		if gfm.IsSeparator(a) || n == 0 { // awk: zero cells is a separator by vacuous truth
			continue
		}
		if !hdone {
			hdone = true
			for k, c := range a {
				switch h := lowerASCII(c); h {
				case "focus":
					fcol = k + 1
				case "status", "estado":
					scol = k + 1
				case "research-state", "state file":
					sfcol = k + 1
				}
			}
			if scol == 0 && fcol > 0 {
				scol = fcol + 1
			}
			continue
		}
		matched := false
		if fcol > 0 && fcol <= n {
			cv := stripMarkup(a[fcol-1])
			matched = cv == sbase || cv == fslug
		}
		if !matched && sfcol > 0 && sfcol <= n {
			cv := stripMarkup(a[sfcol-1])
			matched = cv == sbase || cv == fslug
		}
		if !matched {
			continue
		}
		found = true
		if scol == 0 || scol > n {
			fmt.Fprintf(&w, "WARN: FOCUSES.md row %s: no status column found\n", fslug)
			return "", w.String()
		}
		t := leadTok(a[scol-1])
		for _, v := range focusTokens {
			if t == v {
				return t, w.String()
			}
		}
		fmt.Fprintf(&w, "WARN: FOCUSES.md row %s: unreadable/nonconforming status token [%s]\n", fslug, stripMarkup(a[scol-1]))
		return "", w.String()
	}
	if hdone && !found {
		fmt.Fprintf(&w, "WARN: FOCUSES.md has no row for %s\n", sbase)
	}
	return "", w.String()
}

// focusTokUncached is _read_focuses_tok_uncached ffile sbase: nothing at all when ffile is not a regular file.
func (c *ctx) focusTokUncached(ffile, sbase string) string {
	if !c.isFile(ffile) {
		return ""
	}
	b, err := os.ReadFile(c.abs(ffile))
	if err != nil {
		return ""
	}
	tok, warn := focusTok(string(b), sbase)
	fmt.Fprint(c.s.Err, warn)
	return tok
}

// focusTokCached is _read_focuses_tok_into: the token is computed once per (ffile, sbase) and its WARNs are
// printed by that first read only.
func (c *ctx) focusTokCached(ffile, sbase string) string {
	key := ffile + "\x1e" + sbase
	if t, ok := c.focCache[key]; ok {
		return t
	}
	t := c.focusTokUncached(ffile, sbase)
	if c.focCache == nil {
		c.focCache = map[string]string{}
	}
	c.focCache[key] = t
	return t
}
