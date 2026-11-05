package migratebacklogs

import "strings"

// blanks is the cell padding alphabet of the kit readers: space and tab, nothing else.
const blanks = " \t"

// line is one source line. eol is "\n", "\r\n" or "" (a last line without a terminator), so a file is rebuilt
// byte for byte and a proposal never invents or drops a line ending.
type line struct{ body, eol string }

func (l line) text() string { return l.body + l.eol }

// splitLines cuts src on "\n"; a "\r" right before it belongs to the terminator, not to the line.
func splitLines(src string) []line {
	var out []line
	for len(src) > 0 {
		i := strings.IndexByte(src, '\n')
		if i < 0 {
			out = append(out, line{body: src})
			break
		}
		body, eol := src[:i], "\n"
		if strings.HasSuffix(body, "\r") {
			body, eol = body[:len(body)-1], "\r\n"
		}
		out = append(out, line{body: body, eol: eol})
		src = src[i+1:]
	}
	return out
}

func trim(s string) string { return strings.Trim(s, blanks) }

// lower is the C-locale tolower of the legacy awk: ASCII letters only, so byte offsets never move.
func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// bare is the legacy cell normaliser of the focus registry: trimmed, bold markers and backticks removed.
func bare(s string) string {
	return trim(strings.NewReplacer("**", "", "`", "").Replace(trim(s)))
}
