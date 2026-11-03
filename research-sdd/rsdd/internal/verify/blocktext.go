package verify

import (
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Text primitives of `rsdd verify block`: the GNU grep / gawk / sort / cut behaviours the script leaned on.
// Everything here works on characters (runes) the way the script did under a UTF-8 locale, with POSIX
// leftmost-longest regex semantics (regexp.Longest) and codepoint (byte) collation for sort.

// vbRe compiles a POSIX-style (leftmost-longest) pattern.
func vbRe(p string) *regexp.Regexp {
	r := regexp.MustCompile(p)
	r.Longest()
	return r
}

// grepO is `grep -o`: the non-empty, non-overlapping matches of re in one line.
func grepO(re *regexp.Regexp, line string) []string {
	var out []string
	for _, m := range re.FindAllString(line, -1) {
		if m != "" {
			out = append(out, m)
		}
	}
	return out
}

// grepOLines is `grep -o` over every line of a file's records.
func grepOLines(re *regexp.Regexp, lines []string) []string {
	var out []string
	for _, l := range lines {
		out = append(out, grepO(re, l)...)
	}
	return out
}

// sortU is `sort -u` under a codepoint locale.
func sortU(xs []string) []string {
	if len(xs) == 0 {
		return nil
	}
	c := append([]string(nil), xs...)
	sort.Strings(c)
	out := c[:1]
	for _, x := range c[1:] {
		if x != out[len(out)-1] {
			out = append(out, x)
		}
	}
	return out
}

// nonEmpty drops empty strings (`grep .` / `grep -v '^$'`).
func nonEmpty(xs []string) []string {
	var out []string
	for _, x := range xs {
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

// awkMatch is gawk match(): the 1-based character start and the length in characters of the leftmost-longest match.
func awkMatch(re *regexp.Regexp, s string) (start, length int, ok bool) {
	loc := re.FindStringIndex(s)
	if loc == nil {
		return 0, 0, false
	}
	return utf8.RuneCountInString(s[:loc[0]]) + 1, utf8.RuneCountInString(s[loc[0]:loc[1]]), true
}

// awkSubstr is gawk substr(s, start, length) on characters.
func awkSubstr(s string, start, length int) string {
	r := []rune(s)
	if length <= 0 {
		return ""
	}
	if start < 1 {
		length += start - 1
		start = 1
		if length <= 0 {
			return ""
		}
	}
	if start > len(r) {
		return ""
	}
	end := start - 1 + length
	if end > len(r) {
		end = len(r)
	}
	return string(r[start-1 : end])
}

// awkTail is substr(s, start) on characters.
func awkTail(s string, start int) string { return awkSubstr(s, start, utf8.RuneCountInString(s)+1) }

// awkLower is gawk tolower: one character to one character, so positions stay comparable.
func awkLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r == utf8.RuneError {
			return r
		}
		return unicode.ToLower(r)
	}, s)
}

// blankRe is the backptr awk's blank(): every match of re overwritten by spaces of the same length.
func blankRe(s string, re *regexp.Regexp) string {
	var b strings.Builder
	for {
		loc := re.FindStringIndex(s)
		if loc == nil {
			break
		}
		b.WriteString(s[:loc[0]])
		b.WriteString(strings.Repeat(" ", utf8.RuneCountInString(s[loc[0]:loc[1]])))
		s = s[loc[1]:]
	}
	b.WriteString(s)
	return b.String()
}

// neuterRe is the awk neuter(): the first 3 characters of every match become "xxx", the rest of the match stays.
func neuterRe(s string, re *regexp.Regexp) string {
	var b strings.Builder
	for {
		loc := re.FindStringIndex(s)
		if loc == nil {
			break
		}
		b.WriteString(s[:loc[0]])
		m := []rune(s[loc[0]:loc[1]])
		b.WriteString("xxx")
		if len(m) > 3 {
			b.WriteString(string(m[3:]))
		}
		s = s[loc[1]:]
	}
	b.WriteString(s)
	return b.String()
}

// shellInt is the integer a `[ A -op B ]` test reads: base 10 (leading zeros are not octal), failing on a value
// outside int64 (bash prints "integer expression expected" and the test is false; the message is not reproduced).
func shellInt(s string) (int64, bool) { return shellx.Decimal(s) }

// cutBytes is `cut -c1-n`: GNU cut counts bytes.
func cutBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// trimTabs is the effect of `IFS=$'\t' read` on the last field: leading and trailing tabs are dropped.
func trimTabs(s string) string { return strings.Trim(s, "\t") }

// vbBasename is `basename FILE EXT`-less basename.
func vbStripExt(name string) string {
	if i := strings.LastIndex(name, "."); i >= 0 {
		return name[:i]
	}
	return name
}
