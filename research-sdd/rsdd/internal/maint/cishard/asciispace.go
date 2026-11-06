package cishard

import "strings"

// blank is what the bash runner's `read -r` with the default IFS treats as a separator or padding: ASCII space and
// tab. A '\r', U+0085 or U+00A0 is part of a token, so a CRLF file or a non-ASCII space is never read as clean.
const blank = " \t"

// trimBlank strips ASCII space and tab from both ends.
func trimBlank(s string) string { return strings.Trim(s, blank) }

// fieldsBlank splits on runs of ASCII space and tab only.
func fieldsBlank(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' })
}
