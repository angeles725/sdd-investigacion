package goimpact

// subst is a command substitution found inside a word: `$( ... )` or a backtick pair.
type subst struct {
	body string
	end  int  // index of the closing ')' or backtick
	ok   bool // false when the closer is missing
}

// substAt reports whether a substitution opens at rs[i], and reads it. The body may nest substitutions and
// quotes, which are skipped here and lexed later as their own context.
func substAt(rs []rune, i int) (subst, bool) {
	switch {
	case rs[i] == '$' && i+1 < len(rs) && rs[i+1] == '(':
		end, ok := closeParen(rs, i+2)
		return subst{body: string(rs[min(i+2, end):end]), end: end, ok: ok}, true
	case rs[i] == '`':
		for j := i + 1; j < len(rs); j++ {
			if rs[j] == '\\' {
				j++
			} else if rs[j] == '`' {
				return subst{body: string(rs[i+1 : j]), end: j, ok: true}, true
			}
		}
		return subst{}, true
	}
	return subst{}, false
}

// closeParen returns the index of the ')' that closes a substitution whose body starts at i, skipping quoted
// text and nested substitutions.
func closeParen(rs []rune, i int) (int, bool) {
	for depth := 1; i < len(rs); i++ {
		switch r := rs[i]; {
		case r == '\\':
			i++
		case r == '\'':
			for i++; i < len(rs) && rs[i] != '\''; i++ {
			}
		case r == '"':
			for i++; i < len(rs) && rs[i] != '"'; i++ {
				if rs[i] == '\\' {
					i++
				} else if rs[i] == '$' && i+1 < len(rs) && rs[i+1] == '(' {
					end, ok := closeParen(rs, i+2)
					if !ok {
						return 0, false
					}
					i = end
				}
			}
		case r == '(':
			depth++
		case r == ')':
			if depth--; depth == 0 {
				return i, true
			}
		}
	}
	return 0, false
}
