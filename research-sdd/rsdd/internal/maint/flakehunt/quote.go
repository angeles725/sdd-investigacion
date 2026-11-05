package flakehunt

import (
	"fmt"
	"strings"
)

// shellSpecial are the ASCII characters bash's printf %q backslash-escapes wherever they stand.
const shellSpecial = " !\"$&'()*,;<>?[\\]^`{|}"

// controlEscapes are the named escapes of the $'...' form; any other control byte is a 3-digit octal.
var controlEscapes = map[byte]string{'\a': `\a`, '\b': `\b`, '\f': `\f`, '\n': `\n`, '\r': `\r`, '\t': `\t`, '\v': `\v`, 0x1b: `\E`}

// shQuote is printf %q for one word in a UTF-8 locale: an empty word is two single quotes, a word with a control byte is $'...',
// anything else gets a backslash before each special character (and before a leading # or ~, or a ~ after : or =).
func shQuote(s string) string {
	if s == "" {
		return "''"
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return ansiC(s)
		}
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		prev := byte(0)
		if i > 0 {
			prev = s[i-1]
		}
		if strings.IndexByte(shellSpecial, c) >= 0 || (c == '#' && i == 0) || (c == '~' && (i == 0 || prev == ':' || prev == '=')) {
			b.WriteByte('\\')
		}
		b.WriteByte(c)
	}
	return b.String()
}

// ansiC is the $'...' form, escaping the backslash and the single quote inside it.
func ansiC(s string) string {
	var b strings.Builder
	b.WriteString("$'")
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\' || c == '\'':
			b.WriteByte('\\')
			b.WriteByte(c)
		case controlEscapes[c] != "":
			b.WriteString(controlEscapes[c])
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\%03o`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteString("'")
	return b.String()
}

// shJoin is `printf '%q ' "$@"`: every word followed by one space.
func shJoin(words []string) string {
	var b strings.Builder
	for _, w := range words {
		b.WriteString(shQuote(w))
		b.WriteByte(' ')
	}
	return b.String()
}
