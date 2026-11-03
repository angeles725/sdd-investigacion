package verify

import (
	"regexp"
	"strings"
)

// Text helpers shared by the verify-state port. The bash original reads the state file with awk, grep and sed;
// every helper here names the awk or shell behaviour it reproduces. Classes are those of the C locale
// ([[:space:]] is " \t\n\v\f\r"), matching what gawk and grep do on the ASCII the kit's markup uses.

const wsClass = " \t\n\v\f\r" // [[:space:]]

// recordLines splits src into awk records: "\n" terminates a record, a final fragment without one is still a
// record, and an empty input has none.
func recordLines(src string) []string {
	if src == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(src, "\n"), "\n")
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
	v, ok := decimal(s)
	return ok && v > n
}

// intEQ is `[ "$s" -eq n ]`.
func intEQ(s string, n int64) bool {
	v, ok := decimal(s)
	return ok && v == n
}

func decimal(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	var v int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int64(c - '0')
		if v > (1<<63-1-d)/10 {
			return 0, false
		}
		v = v*10 + d
	}
	return v, true
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
		if reEnvOpen.MatchString(l) {
			in = true
			continue
		}
		if reEnvClose.MatchString(l) {
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
