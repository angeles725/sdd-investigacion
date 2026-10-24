package kit

import "strings"

// Ports of inplace_gap_id and inplace_blocked_count from toolbelt/lib/focus-prefix.sh (kit #1915, METHODOLOGY
// §21.1): the in-place blocked bucket of a Gap-backlog. Character classes are those of LC_ALL=C.

const cSpace = " \t\n\v\f\r" // [[:space:]]

// InplaceGapID is inplace_gap_id: the normalised leading ID token of a gap cell or bullet (leading blanks and `**`,
// then the first word, its trailing `**` and one trailing `.`/`:` dropped, upper-cased). ID-shaped means
// [A-Za-z0-9][A-Za-z0-9.-]* holding a digit or at most 3 characters; false otherwise (a plain word is never an ID).
func InplaceGapID(text string) (string, bool) {
	t := strings.TrimPrefix(strings.TrimLeft(text, cSpace), "**")
	if i := strings.IndexAny(t, cSpace); i >= 0 {
		t = t[:i]
	}
	t = strings.TrimSuffix(t, "**")
	if strings.HasSuffix(t, ".") || strings.HasSuffix(t, ":") { // ${t%[.:]}: one character
		t = t[:len(t)-1]
	}
	if t == "" || !isAlnum(t[0]) || strings.Trim(t, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-") != "" {
		return "", false
	}
	if !strings.ContainsAny(t, "0123456789") && len(t) > 3 {
		return "", false
	}
	return strings.ToUpper(t), true
}

func isAlnum(b byte) bool { return isASCIILetter(b) || b >= '0' && b <= '9' }

// InplaceBlockedCount is inplace_blocked_count body < rows: the OPEN Gap-backlog rows whose leading status token
// is blocked / blocked: / blocked, / blocked-on-* that the Blocked-gaps sections (body) do not already count.
// Closed rows (a struck gap, ~~ or ✅ in the status) are skipped; a row named exactly like a counted bullet (one
// carrying `needs:`), or sharing its gap ID, is counted there and not here.
//
// rows is the backlog_rows stream ("priority<TAB>gap<TAB>status", status lower-cased) read the way
// `while IFS=$'\t' read -r _ gap st` reads it: tab runs collapse (tab is IFS whitespace), the status keeps any
// further tabs, and a last line without a newline is never read.
func InplaceBlockedCount(body, rows string) int {
	names := blockedBulletNames(body)
	ids := map[string]bool{}
	for _, n := range names {
		if id, ok := InplaceGapID(n); ok {
			ids[id] = true
		}
	}
	n := 0
	for _, line := range strings.SplitAfter(rows, "\n") {
		line, complete := strings.CutSuffix(line, "\n")
		_, gap, st := readTabFields(line)
		if !complete || gap == "" || strings.Contains(gap, "~~") || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			continue
		}
		lead := strings.Replace(strings.TrimPrefix(st, "**"), "**", "", 1)
		tok, _, _ := strings.Cut(lead, " ")
		if !strings.HasPrefix(tok, "blocked-on-") && tok != "blocked" && tok != "blocked:" && tok != "blocked," {
			continue
		}
		if id, ok := InplaceGapID(gap); containsString(names, gap) || ok && ids[id] {
			continue
		}
		n++
	}
	return n
}

func containsString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}

// readTabFields is `IFS=$'\t' read -r a b rest`: leading and trailing tabs dropped, a and b split at tab runs,
// rest is the remainder after the run that follows b.
func readTabFields(line string) (a, b, rest string) {
	s := strings.Trim(line, "\t")
	a, s, _ = strings.Cut(s, "\t")
	b, s, _ = strings.Cut(strings.TrimLeft(s, "\t"), "\t")
	return a, b, strings.TrimLeft(s, "\t")
}

// blockedBulletNames is the _blk_names pipeline: the `- … needs:` bullets of body (case-blind needs:) with the
// bullet marker, the `[ — ]needs: …` tail and surrounding blanks removed.
func blockedBulletNames(body string) []string {
	var out []string
	for _, line := range strings.Split(body, "\n") {
		rest := strings.TrimLeft(line, cSpace)
		if !strings.HasPrefix(rest, "-") || len(rest) < 2 || !strings.ContainsRune(cSpace, rune(rest[1])) || needsAt(rest[2:]) < 0 {
			continue
		}
		name := strings.TrimLeft(rest[1:], cSpace)
		name = trimDashRun(strings.TrimRight(name[:needsAt(name)], cSpace))
		out = append(out, strings.Trim(name, cSpace))
	}
	return out
}

// needsAt is the index of the first ASCII-case-blind "needs:" in s, or -1.
func needsAt(s string) int { return strings.Index(asciiLower(s), "needs:") }

// trimDashRun drops a trailing run of the bytes of the C-locale bracket [-–—] ('-' and 0xE2 0x80 0x93 0x94: under
// LC_ALL=C it holds bytes, not characters).
//
// With the first "needs:" at k, the two seds `s/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I` and
// `s/[[:space:]]*needs:.*$//I` together keep exactly s[:k] without its trailing blanks and that dash run: a later,
// dashed needs: cut by the first sed is cut earlier by the second.
func trimDashRun(s string) string {
	w := len(s)
	for w > 0 && strings.IndexByte("-\xe2\x80\x93\x94", s[w-1]) >= 0 {
		w--
	}
	return s[:w]
}
