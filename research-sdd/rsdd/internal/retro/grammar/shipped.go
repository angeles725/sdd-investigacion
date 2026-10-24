package grammar

import (
	"errors"
	"regexp"
	"strconv"
	"strings"
)

// The marker's structured lists (kit issues #949, #1090, #1093, #1944). A marker line is ONE line: the bash
// helpers run sed/grep per line, so text after a line break is outside the contract.

// ErrRangeTooLarge: a shipped/dismissed range spans more than maxRangeIDs ids. Bash would print every id (and
// loops forever on a range ending at the int64 maximum); Go refuses instead of allocating without bound.
var ErrRangeTooLarge = errors.New("grammar: id range too large")

const maxRangeIDs = 100000

var (
	rePartialWord = regexp.MustCompile(`(^|[^A-Za-z])PARTIAL($|[^A-Za-z])`)
	reShippedList = regexp.MustCompile(`shipped:[^;>]*`)
	reParenNote   = regexp.MustCompile(`[[:space:]]*\([^)]*\)`)
	reIDRange     = regexp.MustCompile(`^([A-Za-z]*)([0-9]+)-([A-Za-z]*)([0-9]+)$`)
)

// MarkerIsPartial is retro_marker_is_partial: the STRUCTURED part of the marker (after `review-status:`, before
// `-->`, cut at the first em dash, `shipped:` or `(`) holds the case-sensitive word PARTIAL (#1090); or the part
// cut at the first em dash or `(` only holds the case-sensitive keyword `shipped:` (#1093). Prose after those
// cuts never counts; `Partial` in any other case is not the token.
func MarkerIsPartial(line string) bool {
	if line == "" {
		return false
	}
	body := afterFirst(line, "review-status:")
	body, _, _ = strings.Cut(body, "-->")
	if rePartialWord.MatchString(body[:firstIndex(body, "—", "shipped:", "(")]) {
		return true
	}
	return strings.Contains(body[:firstIndex(body, "—", "(")], "shipped:")
}

// ShippedRaw is retro_marker_shipped_raw: the text after the FIRST `shipped:` (any case) up to `;` or `>`, with a
// `shipped:`/`Shipped:` keyword and its blanks removed (another casing keeps its keyword: kept quirk). No
// parenthetical stripping. "" without the keyword.
func ShippedRaw(line string) string {
	m := grepO(line, reShippedList)
	for _, kw := range []string{"shipped:", "Shipped:"} {
		if strings.HasPrefix(m, kw) {
			return trimLeftSpace(m[len(kw):])
		}
	}
	return m
}

// ShippedIDs is retro_marker_shipped_ids: the ids of a raw list (only its first line), parenthetical notes
// dropped, commas, blanks and tabs separating, one leading `#` stripped, and a same-prefix range `P1-P5`
// expanded (numbers read in base 10, wrapping modulo 2^64 like bash arithmetic; a reversed range yields nothing).
func ShippedIDs(raw string) ([]string, error) {
	s := strings.ReplaceAll(reParenNote.ReplaceAllString(firstLine(raw), ""), ",", " ")
	var out []string
	for _, t := range strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' }) {
		t = strings.TrimPrefix(t, "#")
		if t == "" {
			continue
		}
		m := reIDRange.FindStringSubmatch(t)
		if m == nil || m[1] != m[3] {
			out = append(out, t)
			continue
		}
		ids, err := expandRange(m[1], wrapDecimal(m[2]), wrapDecimal(m[4]))
		if err != nil {
			return nil, err
		}
		out = append(out, ids...)
	}
	return out, nil
}

// expandRange is the bash `for ((j = n1; j <= n2; j++))`, bounded: it stops AT n2 (no wrap past the maximum).
func expandRange(prefix string, n1, n2 int64) ([]string, error) {
	if n1 > n2 {
		return nil, nil
	}
	if uint64(n2)-uint64(n1) >= maxRangeIDs {
		return nil, ErrRangeTooLarge
	}
	var out []string
	for j := n1; ; j++ {
		out = append(out, prefix+strconv.FormatInt(j, 10))
		if j == n2 {
			return out, nil
		}
	}
}

// wrapDecimal is bash `10#digits`: base 10, overflow wrapping modulo 2^64.
func wrapDecimal(digits string) int64 {
	var n uint64
	for i := 0; i < len(digits); i++ {
		n = n*10 + uint64(digits[i]-'0')
	}
	return int64(n)
}

// afterFirst is bash `${s#*sep}`: the text after the first sep, s itself without one.
func afterFirst(s, sep string) string {
	if _, after, ok := strings.Cut(s, sep); ok {
		return after
	}
	return s
}

// firstIndex is the index of the earliest of seps in s, len(s) when none occurs (sed `s/(a|b).*$//`).
func firstIndex(s string, seps ...string) int {
	cut := len(s)
	for _, sep := range seps {
		if i := strings.Index(s, sep); i >= 0 && i < cut {
			cut = i
		}
	}
	return cut
}

// grepO is `grep -oi … | head -1` under LC_ALL=C: the first match of re (a lower-case pattern) in the
// ASCII-folded lines of s, sliced from the original text. Matching per line keeps [[:space:]] from crossing a
// line break, and ASCII folding keeps Go's Unicode case folding (ſ, K) out.
func grepO(s string, re *regexp.Regexp) string {
	for _, line := range strings.Split(s, "\n") {
		if loc := re.FindStringIndex(lower(line)); loc != nil {
			return line[loc[0]:loc[1]]
		}
	}
	return ""
}

// firstLine is s up to its first line break.
func firstLine(s string) string {
	line, _, _ := strings.Cut(s, "\n")
	return line
}
