package grammar

import (
	"regexp"
	"strings"
)

// Cross-retro row identity (kit issues #1709, #1811): reconcile-issues.sh compares a delta's TITLE across retros,
// so the rule that makes a title an identity and the title-column reader live here.

var (
	reTitleHeader = regexp.MustCompile(`^(proposed change|proposed delta|proposal|title|delta|gist|change|rule / change|delta propuesto)`)
	reBoldLead    = regexp.MustCompile(`^\*\*([^*]+)\*\*`)
	bareTokens    = map[string]bool{"high": true, "medium": true, "low": true, "feature": true, "bug": true, "fix": true,
		"bugfix": true, "defect": true, "regression": true, "doc": true, "docs": true, "documentation": true,
		"doc-fix": true, "docfix": true} // RETRO_GRAMMAR_TITLE_TOKEN_CLAUSE
)

// TitleRow is one "<row-id>\037<title>" line of RowTitles.
type TitleRow struct{ ID, Title string }

// Line renders the bash record.
func (r TitleRow) Line() string { return r.ID + "\x1f" + r.Title + "\n" }

// TitleHasIdentity is retro_grammar_title_has_identity: an (already trimmed) title carries a cross-retro identity
// when it is not a bare priority/type token (any case) and has at least 12 CHARACTERS. Input that glibc iconv
// accepts as UTF-8 counts every byte that is not a continuation byte; other input counts bytes, so it is never
// undercounted into a refusal. (Bash skips the validity probe when iconv is missing; Go always has it.)
func TitleHasIdentity(t string) bool {
	lt := lower(t)
	if bareTokens[lt] {
		return false
	}
	n := len(lt)
	if iconvUTF8(lt) {
		n = 0
		for i := 0; i < len(lt); i++ {
			if lt[i]&0xC0 != 0x80 {
				n++
			}
		}
	}
	return n >= 12 // RETRO_GRAMMAR_TITLE_MIN_LEN
}

// iconvUTF8 is `iconv -f UTF-8 -t UTF-8` succeeding under glibc: the original RFC 2279 UTF-8 of 1 to 6 bytes
// (code points up to 0x7FFFFFFF), shortest form only, no UTF-16 surrogate. Go's utf8.ValidString is stricter
// (it stops at U+10FFFF), so it is not used here.
func iconvUTF8(s string) bool {
	minCP := [...]rune{0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000}
	for i := 0; i < len(s); {
		c := s[i]
		n, cp := 0, rune(0)
		switch {
		case c < 0x80:
			i++
			continue
		case c >= 0xC0 && c < 0xE0:
			n, cp = 2, rune(c&0x1F)
		case c >= 0xE0 && c < 0xF0:
			n, cp = 3, rune(c&0x0F)
		case c >= 0xF0 && c < 0xF8:
			n, cp = 4, rune(c&0x07)
		case c >= 0xF8 && c < 0xFC:
			n, cp = 5, rune(c&0x03)
		case c >= 0xFC && c < 0xFE:
			n, cp = 6, rune(c&0x01)
		default:
			return false
		}
		if i+n > len(s) {
			return false
		}
		for k := 1; k < n; k++ {
			if s[i+k]&0xC0 != 0x80 {
				return false
			}
			cp = cp<<6 | rune(s[i+k]&0x3F)
		}
		if cp < minCP[n] || (cp >= 0xD800 && cp <= 0xDFFF) {
			return false
		}
		i += n
	}
	return true
}

// RowTitles is retro_grammar_row_titles: one TitleRow per delta row of the canonical tables, else of the entry
// form. The title is the column the header names (proposed change / delta / title / gist / …), else column 2,
// with a leading **bold** span unwrapped and the ends trimmed. Rows whose id is not IDSignatureSafe are dropped.
func RowTitles(d *Doc) []TitleRow {
	rows, any := tableTitles(d)
	if !any {
		for _, r := range EntryRows(d) {
			rows = append(rows, TitleRow{r.ID, r.Change})
		}
	}
	var out []TitleRow
	for _, r := range rows {
		id := trimSpace(r.ID)
		if id == "" || !IDSignatureSafe(id) { // RETRO_GRAMMAR_ROW_TITLES_ID_SAFE (#2135)
			continue
		}
		out = append(out, TitleRow{id, trimSpace(unbold(r.Title))})
	}
	return out
}

// tableTitles is the awk half of row_titles: the raw (id cell, title cell) of every row under a canonical
// heading. any is true when at least one row was printed, even one with an empty id: such a row still keeps the
// entry form from being consulted.
func tableTitles(d *Doc) (rows []TitleRow, any bool) {
	inSec, prev, ct := false, "", 0
	for _, line := range d.Lines {
		switch {
		case isCanonical(lower(line)):
			inSec, prev, ct = true, "", 0
		case isH2(line):
			inSec = false
		case inSec && reSeparatorRow.MatchString(line):
			if prev != "" {
				ct = titleColumn(splitCells(lower(prev)))
			}
			prev = ""
		case inSec && strings.HasPrefix(line, "|"):
			prev = line
			f := splitCells(line)
			id := cell(f, 1)
			if rid := strings.Map(dropSpace, id); strings.Contains(rid, "|") || titleIDSkip(rid) {
				continue // RETRO_GRAMMAR_ID_PIPE: a pipe in an id is unclassifiable, never a title row
			}
			title := cell(f, 2)
			if ct > 0 {
				title = cell(f, ct)
			}
			rows, any = append(rows, TitleRow{id, title}), true
		}
	}
	return rows, any
}

// titleColumn is the first header cell from column 2 on that names the delta, 0 when none does.
func titleColumn(h []string) int {
	for k := 2; k <= len(h); k++ {
		if reTitleHeader.MatchString(h[k-1]) {
			return k
		}
	}
	return 0
}

// titleIDSkip is the row_titles id guard: separator debris, or a word cell (headerWord). Unlike TableIDSkip it
// also skips a capitalised id such as `SPKI-A`.
func titleIDSkip(rid string) bool { return isDebris(rid) || headerWord(rid) }

// splitCells is the awk cell split of row_titles: every `\|` is an escaped pipe (GFM, kit issues #2118 #2135),
// the leading `|` and a trailing `|` go with their blanks, and the blanks around each inner pipe are the
// separator. Cells keep `|` for an escaped pipe. An empty remainder has no cells.
func splitCells(line string) []string {
	const sent = "\x01"
	s := strings.ReplaceAll(line, `\|`, sent)
	if strings.HasPrefix(s, "|") {
		s = trimLeftSpace(s[1:])
	}
	if t := trimRightSpace(s); strings.HasSuffix(t, "|") {
		s = trimRightSpace(t[:len(t)-1])
	}
	if s == "" {
		return nil
	}
	f := strings.Split(s, "|")
	for i := range f {
		if i > 0 {
			f[i] = trimLeftSpace(f[i])
		}
		if i < len(f)-1 {
			f[i] = trimRightSpace(f[i])
		}
		f[i] = strings.ReplaceAll(f[i], sent, "|")
	}
	return f
}

// cell is awk f[k]: "" past the end.
func cell(f []string, k int) string {
	if k > len(f) {
		return ""
	}
	return f[k-1]
}

// unbold is the sed `s/^\*\*([^*]+)\*\*.*/\1/;t;s/^\*\*//;s/\*\*$//`.
func unbold(s string) string {
	if m := reBoldLead.FindStringSubmatch(s); m != nil {
		return m[1]
	}
	return strings.TrimSuffix(strings.TrimPrefix(s, "**"), "**")
}

func dropSpace(r rune) rune {
	if r < 0x80 && isSpace(byte(r)) {
		return -1
	}
	return r
}
