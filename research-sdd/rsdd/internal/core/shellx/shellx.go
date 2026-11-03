// Package shellx holds the text and path primitives that the verify-* ports share: the shell and awk behaviours
// (basename, dirname, awk records, [[:space:]], a non-negative decimal) reproduced once, so no command carries a
// second copy. Classes are those of the C locale, matching what gawk and grep do on the ASCII the kit's markup uses.
package shellx

import "strings"

// WsClass is [[:space:]] in the C locale.
const WsClass = " \t\n\v\f\r"

// RecordLines splits src into awk records: "\n" terminates a record, a final fragment without one is still a
// record, and an empty input has none.
func RecordLines(src string) []string {
	if src == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(src, "\n"), "\n")
}

// DirName is dirname(1): trailing slashes dropped, the last component cut.
func DirName(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		if p == "" {
			return "."
		}
		return "/"
	}
	i := strings.LastIndex(t, "/")
	if i < 0 {
		return "."
	}
	d := strings.TrimRight(t[:i], "/")
	if d == "" {
		return "/"
	}
	return d
}

// BaseName is basename(1): trailing slashes dropped, the last component kept.
func BaseName(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		if p == "" {
			return ""
		}
		return "/"
	}
	return t[strings.LastIndex(t, "/")+1:]
}

// Decimal parses s as a non-negative base-10 integer made only of ASCII digits (leading zeros allowed, read as
// decimal, never octal). ok is false for an empty string, any other byte, or a value beyond int64.
func Decimal(s string) (int64, bool) {
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
