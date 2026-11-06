package goimpact

import "strings"

// tok is one shell word, or a separator (`;`, `|`, `&`, `(`, `)`, `{`, `}`) when sep is set. A command
// substitution inside a word, quoted or not, is replaced in text by `$()` and its body kept in subs, to be lexed
// as a new command context. bad is the rest of the line after a substitution that never closes.
type tok struct {
	text string
	sep  bool
	subs []string
	bad  string
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
	var subs []string
	flush := func() {
		if cur.Len() > 0 {
			out = append(out, tok{text: cur.String(), subs: subs})
			cur.Reset()
			subs = nil
		}
	}
	rs := []rune(line)
	// take consumes a command substitution opening at rs[i], in a quoted word or not.
	take := func(i int) (next int, hit, bad bool) {
		sb, ok := substAt(rs, i)
		if !ok || !sb.ok {
			return i, ok, ok
		}
		subs = append(subs, sb.body)
		cur.WriteString("$()")
		return sb.end, true, false
	}
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		if n, hit, bad := take(i); hit {
			if bad {
				return append(out, tok{bad: string(rs[i:])})
			}
			i = n
			continue
		}
		switch {
		case r == '\\' && i+1 < len(rs):
			cur.WriteRune(r)
			i++
			cur.WriteRune(rs[i])
		case r == '"' || r == '\'':
			cur.WriteRune(r)
			for i++; i < len(rs); i++ {
				if r == '"' { // single quotes hold substitutions as text
					if n, hit, bad := take(i); hit {
						if bad {
							return append(out, tok{bad: string(rs[i:])})
						}
						i = n
						continue
					}
				}
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
		case r == ' ' || r == '\t':
			flush()
		case r == '#' && cur.Len() == 0:
			flush()
			return out
		case strings.ContainsRune(";|&(){}", r):
			flush()
			out = append(out, tok{text: string(r), sep: true})
		default:
			cur.WriteRune(r)
		}
	}
	flush()
	return out
}
