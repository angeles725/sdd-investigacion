package sizecheck

import (
	"strconv"
	"strings"
)

// entry is one record of `git diff --numstat -z`: counts as git printed them ("-" for a binary file), the path, and
// the old path of a rename.
type entry struct {
	add, del  string
	path, old string
}

// cutTab splits at the first tab; without one both halves are the whole text (the bash ${t%%\t*} / ${t#*\t}).
func cutTab(s string) (before, after string) {
	if i := strings.IndexByte(s, '\t'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, s
}

// parseNumstat reads the NUL-terminated records: "A\tD\tpath\0" or, for a rename, "A\tD\t\0old\0new\0". A trailing
// piece without its NUL is dropped, as the bash read loop never delivers it. A malformed rename, a control character in a
// path or a count that is neither digits nor "-" is a failure (the bash tool refused the first two and computed with
// garbage on the third).
func parseNumstat(raw string) ([]entry, string) {
	toks := strings.Split(raw, "\x00")
	toks = toks[:len(toks)-1]
	var out []entry
	for i := 0; i < len(toks); {
		t := toks[i]
		i++
		a, rest := cutTab(t)
		d, p := cutTab(rest)
		old := ""
		if p == "" {
			if i+2 > len(toks) {
				return nil, "malformed rename record in numstat"
			}
			old, p = toks[i], toks[i+1]
			i += 2
			if p == "" {
				return nil, "malformed rename record in numstat"
			}
		}
		if hasControl(p + old) {
			return nil, "unsupported path (control character: tab, newline, CR...) in diff"
		}
		if !count(a) || !count(d) {
			return nil, "malformed numstat record for " + p
		}
		out = append(out, entry{add: a, del: d, path: p, old: old})
	}
	return out, ""
}

// count is what git prints for a measured file (digits) or a binary one.
func count(s string) bool { return s == "-" || digits(s) }

// hasControl is `[[:cntrl:]]` in the C locale: a byte below space, or DEL.
func hasControl(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return true
		}
	}
	return false
}

// num is a count git printed; callers have checked it with count().
func num(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}
