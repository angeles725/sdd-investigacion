package goimpact

import "strings"

// tok is one shell word, or a separator (`;`, `|`, `&`, `(`, `)`, `{`, `}`, a backtick or `$(`) when sep is set.
type tok struct {
	text string
	sep  bool
}

// logicalLines joins backslash-continued lines.
func logicalLines(text string) []string {
	var out []string
	var cur strings.Builder
	for _, l := range strings.Split(text, "\n") {
		if strings.HasSuffix(l, "\\") {
			cur.WriteString(strings.TrimSuffix(l, "\\"))
			cur.WriteByte(' ')
			continue
		}
		cur.WriteString(l)
		out = append(out, cur.String())
		cur.Reset()
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// lex splits one logical line into words and separators. It is quote-aware (single, double, backslash), keeps
// `${...}` inside its word, and stops at a comment word. It is not a shell parser: it only has to find words in
// command position, and anything it mis-splits can only turn a real call into an unclassifiable one or an
// extra caller, both of which fail closed.
func lex(line string) []tok {
	var out []tok
	var cur strings.Builder
	flush := func() {
		if cur.Len() > 0 {
			out = append(out, tok{text: cur.String()})
			cur.Reset()
		}
	}
	rs := []rune(line)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch {
		case r == '\\' && i+1 < len(rs):
			cur.WriteRune(r)
			i++
			cur.WriteRune(rs[i])
		case r == '"' || r == '\'':
			cur.WriteRune(r)
			for i++; i < len(rs); i++ {
				cur.WriteRune(rs[i])
				if rs[i] == '\\' && r == '"' && i+1 < len(rs) {
					i++
					cur.WriteRune(rs[i])
				} else if rs[i] == r {
					break
				}
			}
		case r == '$' && i+1 < len(rs) && rs[i+1] == '{':
			for ; i < len(rs); i++ {
				cur.WriteRune(rs[i])
				if rs[i] == '}' {
					break
				}
			}
		case r == '$' && i+1 < len(rs) && rs[i+1] == '(':
			flush()
			out = append(out, tok{text: "$(", sep: true})
			i++
		case r == ' ' || r == '\t':
			flush()
		case r == '#' && cur.Len() == 0:
			flush()
			return out
		case strings.ContainsRune(";|&(){}`", r):
			flush()
			out = append(out, tok{text: string(r), sep: true})
		default:
			cur.WriteRune(r)
		}
	}
	flush()
	return out
}
