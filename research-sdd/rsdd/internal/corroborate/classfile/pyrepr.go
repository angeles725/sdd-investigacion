package classfile

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// pyRepr renders s the way Python's repr(str) does for a value read from the environment: a byte that is not
// valid UTF-8 is the lone surrogate U+DC80..U+DCFF that os.environ decodes it to (surrogateescape), and
// is shown as \udcXX.
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		quote = '"'
	}
	var sb strings.Builder
	sb.WriteByte(quote)
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && n == 1:
			fmt.Fprintf(&sb, "\\udc%02x", s[i])
		case r == rune(quote) || r == '\\':
			sb.WriteByte('\\')
			sb.WriteRune(r)
		case r == '\t':
			sb.WriteString(`\t`)
		case r == '\n':
			sb.WriteString(`\n`)
		case r == '\r':
			sb.WriteString(`\r`)
		case unicode.IsPrint(r):
			sb.WriteRune(r)
		default:
			// Escape width by the number of hex digits the code point needs: \xNN, \uNNNN or \UNNNNNNNN.
			switch digits := len(strconv.FormatUint(uint64(r), 16)); {
			case digits <= 2:
				fmt.Fprintf(&sb, "\\x%02x", r)
			case digits <= 4:
				fmt.Fprintf(&sb, "\\u%04x", r)
			default:
				fmt.Fprintf(&sb, "\\U%08x", r)
			}
		}
		i += n
	}
	sb.WriteByte(quote)
	return sb.String()
}
