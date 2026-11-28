package verify

import (
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Text helpers shared by the verify-state port. The bash original reads the state file with awk, grep and sed;
// every helper here names the awk or shell behaviour it reproduces. Classes are those of the C locale
// ([[:space:]] is " \t\n\v\f\r"), matching what gawk and grep do on the ASCII the kit's markup uses.

// mayContainFold is a cheap pre-filter for a (?i) regexp whose every match contains one of lits (lower-case ASCII
// text): false means the regexp cannot match l, true means it may. The only non-ASCII characters Go's case folding
// maps onto an ASCII letter are U+017F (to "s") and U+212A (to "k"); a line holding either is never filtered.
func mayContainFold(l string, lits ...string) bool {
	if hasFoldChar(l) {
		return true
	}
	for _, lit := range lits {
		if containsASCIIFold(l, lit) {
			return true
		}
	}
	return false
}

// foldAlt is a (?i) regexp that is an alternation of plain ASCII literals, together with those literals (lower-case).
// A line holding no non-ASCII fold character is decided by a literal search; only such a character (see hasFoldChar)
// sends the line to the regexp. lits must spell exactly the language of re: TestFoldAltAgreesWithRegexp pins it.
type foldAlt struct {
	re   *regexp.Regexp
	lits []string
}

// MatchString is re.MatchString(l).
func (f foldAlt) MatchString(l string) bool {
	if hasFoldChar(l) {
		return f.re.MatchString(l)
	}
	for _, lit := range f.lits {
		if containsASCIIFold(l, lit) {
			return true
		}
	}
	return false
}

// hasFoldChar reports whether l holds a non-ASCII character that Go's case folding maps onto an ASCII letter:
// U+017F (to "s") or U+212A (to "k"). On any other line a (?i) match of ASCII text is an ASCII-only fold.
func hasFoldChar(l string) bool {
	return strings.Contains(l, "\u017f") || strings.Contains(l, "\u212a")
}

// containsASCIIFold is strings.Contains(asciiLower(s), lit) for a lower-case lit, without building the lower-cased
// copy: this runs on every line of every state file, and the copy was the run's largest allocation (kit issue #2686).
func containsASCIIFold(s, lit string) bool {
	n := len(lit)
	if n == 0 {
		return true
	}
	first, upper := lit[0], lit[0]
	if first >= 'a' && first <= 'z' {
		upper = first - ('a' - 'A')
	}
	for i := 0; i+n <= len(s); i++ {
		if c := s[i]; (c == first || c == upper) && foldEqual(s[i+1:i+n], lit[1:]) {
			return true
		}
	}
	return false
}

// foldEqual reports whether s lower-cased (ASCII only) is lit; s and lit have the same length.
func foldEqual(s, lit string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != lit[i] {
			return false
		}
	}
	return true
}

// asciiLower is awk tolower on ASCII (the only case the kit's tokens use).
func asciiLower(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			b := []byte(s)
			for j := i; j < len(b); j++ {
				if b[j] >= 'A' && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return s
}

// asciiUpper is awk toupper on ASCII.
func asciiUpper(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - ('a' - 'A')
		}
	}
	return string(b)
}

// trimBlanks is gsub(/^[ \t]+|[ \t]+$/, "", s).
func trimBlanks(s string) string { return strings.Trim(s, " \t") }

// splitPipeCells is the awk row split used by the backlog readers: blanks trimmed, one leading and one trailing
// pipe removed, an escaped pipe kept inside its cell, then split("|"). n is split's return value: an empty
// string has 0 fields (Go's Split would say 1).
func splitPipeCells(line string) (cells []string, n int) {
	line = strings.ReplaceAll(line, `\|`, "\x01")
	line = strings.TrimPrefix(line, "|")
	line = strings.TrimSuffix(line, "|")
	if line == "" {
		return nil, 0
	}
	cells = strings.Split(line, "|")
	for i, c := range cells {
		cells[i] = strings.ReplaceAll(trimBlanks(c), "\x01", "|")
	}
	return cells, len(cells)
}

// cell is a[i] (1-based): awk's uninitialised element is "".
func cell(a []string, i int) string {
	if i < 1 || i > len(a) {
		return ""
	}
	return a[i-1]
}

// readTabFields is `IFS=$'\t' read -r a b rest`: leading and trailing tabs dropped, a and b split at tab runs
// (so an empty middle cell collapses), rest is the remainder after the run that follows b.
func readTabFields(line string) (a, b, rest string) {
	s := strings.Trim(line, "\t")
	a, s, _ = strings.Cut(s, "\t")
	b, s, _ = strings.Cut(strings.TrimLeft(s, "\t"), "\t")
	return a, b, strings.TrimLeft(s, "\t")
}

// firstWord is "${s%% *}": everything before the first space.
func firstWord(s string) string {
	if i := strings.IndexByte(s, ' '); i >= 0 {
		return s[:i]
	}
	return s
}

// stripBold is the lead/tok derivation of the row classifiers: lead="${st#\*\*}"; lead="${lead/\*\*/}".
func stripBold(st string) string {
	lead := strings.TrimPrefix(st, "**")
	return strings.Replace(lead, "**", "", 1)
}

// isInt is the script's is_int: digits only, non-empty.
func isInt(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// intGT is `[ "$s" -gt n ]` for an is_int string: decimal, leading zeros ignored. A value beyond int64 makes
// bash's test fail with an error (false); here it is the same false.
func intGT(s string, n int64) bool {
	v, ok := shellx.Decimal(s)
	return ok && v > n
}

// intEQ is `[ "$s" -eq n ]`.
func intEQ(s string, n int64) bool {
	v, ok := shellx.Decimal(s)
	return ok && v == n
}

// envelope markers: the awk patterns /<!-- research-state.v1 -->/ and /<!-- \/research-state.v1 -->/ (the dots
// are regex dots, as in the script).
var (
	reEnvOpen  = regexp.MustCompile(`<!-- research-state.v1 -->`)
	reEnvClose = regexp.MustCompile(`<!-- /research-state.v1 -->`)
)

// scanEnvelope walks lines through the script's recurring awk state machine
//
//	/open/ {b=1; next}   /close/ {b=0}   b && COND {ACT; exit}
//
// and returns the first line inside an envelope for which match is true. The close marker does not stop the
// scan (a state file may carry several envelopes).
func scanEnvelope(lines []string, match func(line string) bool) (string, bool) {
	in := false
	for _, l := range lines {
		// Both markers are HTML comments: a line without "<!--" is neither, and nearly every line is that (kit issue #2686).
		if marker := strings.Contains(l, "<!--"); marker && reEnvOpen.MatchString(l) {
			in = true
			continue
		} else if marker && reEnvClose.MatchString(l) {
			in = false
		}
		if in && match(l) {
			return l, true
		}
	}
	return "", false
}

// envField is env_field: the value after "key:" on the first envelope line whose first blank-separated field is
// "key:", with a trailing CR removed. Empty when the key is absent or has no value.
func envField(lines []string, key string) string {
	var v string
	scanEnvelope(lines, func(l string) bool {
		f := awkFields(l)
		if len(f) > 0 && f[0] == key+":" {
			if len(f) > 1 {
				v = strings.TrimSuffix(f[1], "\r")
			}
			return true
		}
		return false
	})
	return v
}

// envProbe is the `awk '... b && /^[[:space:]]*KEY:/{print; exit}'` presence probe: the first envelope line that
// starts with the key (after blanks), "" when none. The probe sees `key:value` typos that env_field cannot.
func envProbe(lines []string, key string) string {
	re := regexp.MustCompile(`^[ \t\n\v\f\r]*` + regexp.QuoteMeta(key) + `:`)
	l, _ := scanEnvelope(lines, re.MatchString)
	return l
}

// awkFields is awk's default field splitting: runs of blanks, tabs and newlines, none at the ends.
func awkFields(l string) []string {
	return strings.FieldsFunc(l, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// section is the script's _section / blocked_rows_section: the body of every "## ..." section whose heading line
// starts with h (index($0,h)==1), the heading lines themselves left out. The text ends with "\n" after each line,
// as awk prints it.
func section(lines []string, h string) []string {
	var out []string
	f := false
	for _, l := range lines {
		switch {
		case strings.HasPrefix(l, h):
			f = true
		case strings.HasPrefix(l, "## "):
			f = false
		case f:
			out = append(out, l)
		}
	}
	return out
}

// joinLines renders lines the way awk prints them: each followed by a newline.
func joinLines(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}

// cmdSubst is "$(...)": trailing newlines are removed.
func cmdSubst(s string) string { return strings.TrimRight(s, "\n") }

// bodyLines is `printf '%s\n' "$body"` read back as records: the substituted body plus the newline printf adds
// (an empty body is one empty line).
func bodyLines(body string) []string { return strings.Split(body, "\n") }
