package console

import (
	"fmt"
	"strings"
	"unicode"
	"unicode/utf8"
)

// The two error messages of the script that name a path are written by coreutils, not by the script: mkdir quotes
// the name with its locale quoting style and tee with its shell-escape style, and both choose their text by the
// locale. The port reproduces both, for the C locale and for a UTF-8 one, so the line a caller reads is the line
// the script printed.

// utf8Locale reports whether the quoting charset is UTF-8: the first non-empty of LC_ALL, LC_CTYPE and LANG names
// a codeset (after the dot, before any @modifier) of UTF-8. A UTF-8 locale that is not installed falls back to C in
// coreutils; the port cannot see that and answers for the name it was given.
func (e *env) utf8Locale() bool {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		v := e.s.Env(k)
		if v == "" {
			continue
		}
		_, codeset, ok := strings.Cut(v, ".")
		if !ok {
			return false
		}
		codeset, _, _ = strings.Cut(codeset, "@")
		return strings.EqualFold(codeset, "utf-8") || strings.EqualFold(codeset, "utf8")
	}
	return false
}

// escape is the backslash letter of a control byte, or "" when it has none.
func escape(b byte) string {
	switch b {
	case '\a':
		return `\a`
	case '\b':
		return `\b`
	case '\t':
		return `\t`
	case '\n':
		return `\n`
	case '\v':
		return `\v`
	case '\f':
		return `\f`
	case '\r':
		return `\r`
	}
	return ""
}

func octal(b byte) string { return fmt.Sprintf(`\%03o`, b) }

// quoteC is gnulib's locale quoting style, as mkdir prints a name: inside '...' in the C locale and inside
// the typographic pair in UTF-8, a backslash and the closing quote escaped, a control byte as \t \n ... or
// \ooo, and a byte that is not a printable character of the locale as \ooo.
func (e *env) quoteC(s string) string {
	utf := e.utf8Locale()
	open, closeQ := "'", "'"
	if utf {
		open, closeQ = "‘", "’"
	}
	var b strings.Builder
	b.WriteString(open)
	for i := 0; i < len(s); {
		c := s[i]
		r, w := rune(c), 1
		if utf { // an ASCII byte decodes as itself; a byte that starts no valid sequence is RuneError, width 1
			r, w = utf8.DecodeRuneInString(s[i:])
		}
		switch {
		case c == '\\':
			b.WriteString(`\\`)
		case escape(c) != "":
			b.WriteString(escape(c))
		case c < 0x20 || c == 0x7f || w == 1 && c >= 0x80: // a control byte, or one that is not a character
			b.WriteString(octal(c))
		case s[i:i+w] == closeQ:
			b.WriteString(`\` + closeQ)
		case c >= 0x80 && !unicode.IsPrint(r): // a multibyte character the locale cannot print
			for _, x := range []byte(s[i : i+w]) {
				b.WriteString(octal(x))
			}
		default:
			b.WriteString(s[i : i+w])
		}
		i += w
	}
	b.WriteString(closeQ)
	return b.String()
}

// shellSpecial are the printable ASCII characters that make coreutils quote a name for the shell.
const shellSpecial = " !\"$&'()*:;<=>?[\\^`|"

// quoteShell is gnulib's shell-escape quoting style, as tee prints a name: bare when it is safe, '...' when it
// needs quoting, "..." when its only reason is an apostrophe, and $'\ooo' runs for characters that cannot be
// printed.
func (e *env) quoteShell(s string) string {
	utf := e.utf8Locale()
	type ch struct {
		text string // what to print for a printable character
		bad  bool   // not printable: one byte, printed in a $'...' run
		b    byte
	}
	var cs []ch
	need := s == "{" || s == "}" || strings.HasPrefix(s, "~") || strings.HasPrefix(s, "#")
	for i := 0; i < len(s); {
		c := s[i]
		r, w := rune(c), 1
		if utf {
			r, w = utf8.DecodeRuneInString(s[i:])
		}
		if c < 0x20 || c == 0x7f || c >= 0x80 && (w == 1 || !unicode.IsPrint(r)) {
			for _, x := range []byte(s[i : i+w]) {
				cs = append(cs, ch{bad: true, b: x})
			}
			need = true
		} else {
			cs = append(cs, ch{text: s[i : i+w]})
			need = need || w == 1 && strings.IndexByte(shellSpecial, c) >= 0
		}
		i += w
	}
	if !need {
		return s
	}
	plain := true
	for _, c := range cs {
		plain = plain && !c.bad
	}
	if plain && strings.Contains(s, "'") && !strings.ContainsAny(s, "\"$`\\") {
		return `"` + s + `"`
	}
	var b strings.Builder
	state := byte(0) // 0 outside quotes, '\'' inside '...', '$' inside $'...'
	closeRun := func() {
		if state != 0 {
			b.WriteByte('\'')
			state = 0
		}
	}
	for _, c := range cs {
		switch {
		case c.bad:
			if state != '$' {
				closeRun()
				b.WriteString("$'")
				state = '$'
			}
			if esc := escape(c.b); esc != "" {
				b.WriteString(esc)
			} else {
				b.WriteString(octal(c.b))
			}
		case c.text == "'":
			closeRun()
			b.WriteString(`\'`)
		default:
			if state != '\'' {
				closeRun()
				b.WriteByte('\'')
				state = '\''
			}
			b.WriteString(c.text)
		}
	}
	closeRun()
	return b.String()
}
