package corpus

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// archiveQuote is bash's `printf '%q'`. A string with control bytes (or, outside a UTF-8 locale, any non-ASCII byte)
// becomes an ANSI-C `$'...'` word; otherwise each shell-special character is backslash-escaped. Measured against
// bash 5 for every ASCII byte: the escaped set is the one below, `#` and `~` only at the start of the word.
func archiveQuote(s string, utf8Locale bool) string {
	if s == "" {
		return "''"
	}
	needANSI := false
	for i := 0; i < len(s); i++ {
		b := s[i]
		if b < 0x20 || b == 0x7f || (b >= 0x80 && !utf8Locale) {
			needANSI = true
		}
	}
	if !needANSI && utf8Locale {
		for _, r := range s {
			if r == utf8.RuneError || !unicode.IsPrint(r) {
				needANSI = true
			}
		}
	}
	if needANSI {
		return archiveQuoteANSI(s, utf8Locale)
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte(" !\"$&'()*,;<>?[\\]^`{|}", c) >= 0 || (i == 0 && (c == '#' || c == '~')) {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

func archiveQuoteANSI(s string, utf8Locale bool) string {
	var b strings.Builder
	b.WriteString("$'")
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '\\' || c == '\'':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == 7:
			b.WriteString(`\a`)
		case c == 8:
			b.WriteString(`\b`)
		case c == 9:
			b.WriteString(`\t`)
		case c == 10:
			b.WriteString(`\n`)
		case c == 11:
			b.WriteString(`\v`)
		case c == 12:
			b.WriteString(`\f`)
		case c == 13:
			b.WriteString(`\r`)
		case c == 27:
			b.WriteString(`\E`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\%03o`, c)
		case c < 0x80:
			b.WriteByte(c)
		default:
			r, size := utf8.DecodeRuneInString(s[i:])
			if utf8Locale && r != utf8.RuneError && unicode.IsPrint(r) {
				b.WriteString(s[i : i+size])
				i += size
				continue
			}
			fmt.Fprintf(&b, `\%03o`, c)
		}
		i++
	}
	b.WriteByte('\'')
	return b.String()
}

// archiveUTF8Locale is glibc's rule for the character set: LC_ALL, then LC_CTYPE, then LANG.
func archiveUTF8Locale(env func(string) string) bool {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v := env(k); v != "" {
			v = strings.ToLower(v)
			return strings.Contains(v, "utf-8") || strings.Contains(v, "utf8")
		}
	}
	return false
}
