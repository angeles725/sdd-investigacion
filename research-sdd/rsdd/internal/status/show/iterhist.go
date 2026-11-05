package show

import (
	"strconv"
	"strings"
)

// Port of iter_gaps_rows: the typed stream of the "## Iteration history" table. The New-gaps column is selected by
// header name (/new gaps|nuevos gaps/i), never by position (issue #420).

// iterRec is one record of the stream. kind is "row" (a parsable numeric index) or "struct" (an unnumbered
// bootstrap/reopen/synthesis row; sk is its position). status is "ok" or "bad"; val is the count (ok) or the raw
// cell (bad), cut at its first tab as the awk consumers read it.
type iterRec struct {
	kind, sk, status, val string
}

func (r iterRec) line() string { return r.sk + "\t" + r.status + "\t" + r.val }

// iterStream parses the section body. colNone is the header of a table without a New-gaps column.
func iterStream(body string) (recs []iterRec, colNone string, noColumn bool) {
	haveHeader, ngcol, seq := false, 0, 0
	for _, raw := range splitLines(body) {
		if strings.Contains(raw, "<!--") || strings.Contains(raw, "-->") {
			continue
		}
		l := trimBlanks(raw)
		if !strings.Contains(l, "|") {
			continue
		}
		l = strings.ReplaceAll(l, `\|`, "\x01") // GFM-EP-ITER
		l = strings.TrimSuffix(strings.TrimPrefix(l, "|"), "|")
		var cells []string
		if l != "" { // awk's split of "" has no fields
			cells = strings.Split(l, "|")
		}
		for k := range cells {
			cells[k] = strings.ReplaceAll(trimBlanks(cells[k]), "\x01", "|")
		}
		if isSeparatorRow(cells) {
			continue
		}
		if !haveHeader {
			haveHeader = true
			for k, c := range cells {
				if lc := lowerASCII(c); strings.Contains(lc, "new gaps") || strings.Contains(lc, "nuevos gaps") {
					ngcol = k + 1
					break
				}
			}
			if ngcol == 0 { // GFM-EP-HDR-RESTORE
				return nil, clipTab(strings.ReplaceAll(l, "\x01", "|")), true
			}
			continue
		}
		seq++
		if hasPlaceholder(cells) {
			continue
		}
		recs = append(recs, iterRow(cells, ngcol, seq))
	}
	return recs, "", false
}

// isSeparatorRow is "every cell matches ^:?-+:?$" (a row with no cell at all counts).
func isSeparatorRow(cells []string) bool {
	for _, c := range cells {
		if !isAllDashes(strings.TrimSuffix(strings.TrimPrefix(c, ":"), ":")) {
			return false
		}
	}
	return true
}

// hasPlaceholder is a <...> template cell anywhere in the row.
func hasPlaceholder(cells []string) bool {
	for _, c := range cells {
		if len(c) >= 2 && c[0] == '<' && c[len(c)-1] == '>' {
			return true
		}
	}
	return false
}

// iterRow classifies one data row.
func iterRow(cells []string, ngcol, seq int) iterRec {
	cell := ""
	if ngcol <= len(cells) {
		cell = cells[ngcol-1]
	}
	idx := strings.TrimPrefix(cells[0], "it.")
	kind, sk := "struct", strconv.Itoa(seq)
	if n := leadingDigits(idx); n > 0 {
		kind, sk = "row", idx[:n]
	}
	rec := iterRec{kind: kind, sk: sk, status: "bad"}
	lc := lowerASCII(cell)
	switch v := strings.TrimPrefix(cell, "+"); {
	case cell == "":
		rec.val = "(empty)"
	case leadingDigits(v) > 0:
		rec.status, rec.val = "ok", awkInt(v[:leadingDigits(v)])
	case strings.HasPrefix(lc, "none") || strings.HasPrefix(lc, "ningun") || strings.HasPrefix(lc, "ningún"): // NG-NONE
		rec.status, rec.val = "ok", "0"
	default:
		rec.val = clipTab(cell)
	}
	return rec
}

// leadingDigits is the length of the run of digits at the start of s.
func leadingDigits(s string) int {
	n := 0
	for n < len(s) && isDigit(s[n]) {
		n++
	}
	return n
}

// awkInt is `digits+0` as awk prints it: the value of the double, without leading zeros.
func awkInt(digits string) string {
	f, _ := strconv.ParseFloat(digits, 64)
	return strconv.FormatFloat(f, 'f', -1, 64)
}

// clipTab is the first tab-separated field, which is all awk -F'\t' reads of a cell.
func clipTab(s string) string {
	head, _, _ := strings.Cut(s, "\t")
	return head
}
