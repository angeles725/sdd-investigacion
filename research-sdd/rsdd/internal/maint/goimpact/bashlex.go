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
	pending := false
	for _, l := range strings.Split(text, "\n") {
		cur.WriteString(strings.TrimSuffix(l, "\\"))
		if pending = strings.HasSuffix(l, "\\"); pending {
			cur.WriteByte(' ')
			continue
		}
		out = append(out, cur.String())
		cur.Reset()
	}
	if pending {
		out = append(out, cur.String())
	}
	return out
}

// lexer holds the state of one lex call: the word being built, the substitutions inside it, and the tokens so far.
type lexer struct {
	s    string
	cur  strings.Builder
	subs []string
	out  []tok
	stop bool   // a comment ends the line, or a substitution never closed
	bad  string // the unclosed rest of the line
}

func (l *lexer) flush() {
	if l.cur.Len() != 0 {
		l.out = append(l.out, tok{text: l.cur.String(), subs: l.subs})
		l.cur.Reset()
		l.subs = nil
	}
}

// pair writes the two bytes at i (a backslash and what it escapes) and returns the index of the second.
func (l *lexer) pair(i int) int {
	end := min(i+2, len(l.s))
	l.cur.WriteString(l.s[i:end])
	return end - 1
}

// sub consumes the substitution opening at i, if any, and returns the index of its closer.
func (l *lexer) sub(i int) (next int, hit bool) {
	sb, hit := substAt(l.s, i)
	if !hit {
		return i, false
	}
	if !sb.ok {
		l.stop, l.bad = true, l.s[i:]
		return len(l.s), true
	}
	l.subs = append(l.subs, sb.body)
	l.cur.WriteString("$()")
	return sb.end, true
}

// single copies a single-quoted text starting at i, up to and including its closing quote.
func (l *lexer) single(i int) int {
	end := len(l.s)
	if k := strings.IndexByte(l.s[i+1:], '\''); k != -1 {
		end = i + k + 2
	}
	l.cur.WriteString(l.s[i:end])
	return end - 1
}

// double copies a double-quoted text starting at i; a substitution inside it is a new command context.
func (l *lexer) double(i int) int {
	l.cur.WriteByte('"')
	for i++; i < len(l.s) && !l.stop; i++ {
		if l.s[i] == '\\' {
			i = l.pair(i)
			continue
		}
		if n, hit := l.sub(i); hit {
			i = n
			continue
		}
		l.cur.WriteByte(l.s[i])
		if l.s[i] == '"' {
			break
		}
	}
	return i
}

// brace copies a `${...}` parameter expansion starting at i.
func (l *lexer) brace(i int) int {
	end := len(l.s)
	if k := strings.IndexByte(l.s[i:], '}'); k != -1 {
		end = i + k + 1
	}
	l.cur.WriteString(l.s[i:end])
	return end - 1
}

// step lexes the byte at i and returns the index of the last byte it consumed.
func (l *lexer) step(i int) int {
	c := l.s[i]
	switch c {
	case '\\':
		return l.pair(i)
	case '\'':
		return l.single(i)
	case '"':
		return l.double(i)
	case '$', '`':
		if n, hit := l.sub(i); hit {
			return n
		}
		if strings.HasPrefix(l.s[i:], "${") {
			return l.brace(i)
		}
	case ' ', '\t':
		l.flush()
		return i
	case '#':
		if l.cur.Len() == 0 {
			l.stop = true
			return i
		}
	case ';', '|', '&', '(', ')', '{', '}':
		l.flush()
		l.out = append(l.out, tok{text: string(c), sep: true})
		return i
	}
	l.cur.WriteByte(c)
	return i
}

// lex splits one logical line into words and separators. It is quote-aware (single, double, backslash), keeps
// `${...}` inside its word, and stops at a comment word. A command substitution, in a double-quoted word or
// not, becomes a new command context (see tok). It is not a shell parser: it only has to find words in command
// position, and anything it mis-splits can only turn a real call into a blind spot or an extra caller, both of
// which fail closed.
func lex(line string) []tok {
	l := &lexer{s: line}
	for i := 0; i < len(l.s) && !l.stop; i++ {
		i = l.step(i)
	}
	if l.bad != "" {
		return append(l.out, tok{bad: l.bad})
	}
	l.flush()
	return l.out
}
