package cleancheck

// globMatch is bash's `[[ s == pattern ]]`: * and ? (both also match /), bracket expressions with ! or ^ negation,
// ranges and POSIX classes, and backslash quoting. An unterminated [ is a literal. Characters are runes.
func globMatch(pattern, s string) bool {
	p, t := []rune(pattern), []rune(s)
	pi, ti := 0, 0
	star, mark := -1, 0
	for ti < len(t) {
		if pi < len(p) {
			switch p[pi] {
			case '*':
				star, mark = pi, ti
				pi++
				continue
			case '?':
				pi++
				ti++
				continue
			case '[':
				if ok, next, valid := bracket(p, pi, t[ti]); valid {
					if ok {
						pi, ti = next, ti+1
						continue
					}
					goto backtrack
				}
			case '\\':
				if pi+1 < len(p) {
					if p[pi+1] == t[ti] {
						pi, ti = pi+2, ti+1
						continue
					}
					goto backtrack
				}
			}
			if p[pi] == t[ti] {
				pi, ti = pi+1, ti+1
				continue
			}
		}
	backtrack:
		if star < 0 {
			return false
		}
		mark++
		pi, ti = star+1, mark
	}
	for pi < len(p) && p[pi] == '*' {
		pi++
	}
	return pi == len(p)
}

// bracket matches c against the bracket expression starting at p[i]. valid is false when it is not terminated (the
// [ is then an ordinary character); next is the index after the closing ].
func bracket(p []rune, i int, c rune) (match bool, next int, valid bool) {
	j := i + 1
	negate := false
	if j < len(p) && (p[j] == '!' || p[j] == '^') {
		negate = true
		j++
	}
	first := true
	for j < len(p) {
		if p[j] == ']' && !first {
			return match != negate, j + 1, true
		}
		first = false
		lo, w, class := bracketItem(p, j)
		switch {
		case class != nil:
			if class(c) {
				match = true
			}
			j += w
		case j+w+1 < len(p) && p[j+w] == '-' && p[j+w+1] != ']':
			hi, w2, _ := bracketItem(p, j+w+1)
			if lo <= c && c <= hi {
				match = true
			}
			j += w + 1 + w2
		default:
			if lo == c {
				match = true
			}
			j += w
		}
	}
	return false, 0, false
}

// bracketItem reads one element at p[j]: a character (a backslash quotes the next one), or a [:class:].
func bracketItem(p []rune, j int) (r rune, width int, class func(rune) bool) {
	if p[j] == '[' && j+1 < len(p) && p[j+1] == ':' {
		for k := j + 2; k+1 < len(p); k++ {
			if p[k] == ':' && p[k+1] == ']' {
				f, ok := classes[string(p[j+2:k])]
				if !ok { // bash: an unknown class matches nothing
					f = func(rune) bool { return false }
				}
				return 0, k + 2 - j, f
			}
		}
	}
	if p[j] == '\\' && j+1 < len(p) {
		return p[j+1], 2, nil
	}
	return p[j], 1, nil
}

var classes = map[string]func(rune) bool{
	"alpha": func(c rune) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' },
	"digit": func(c rune) bool { return c >= '0' && c <= '9' },
	"alnum": func(c rune) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' },
	"upper": func(c rune) bool { return c >= 'A' && c <= 'Z' },
	"lower": func(c rune) bool { return c >= 'a' && c <= 'z' },
	"space": func(c rune) bool { return c == ' ' || c >= '\t' && c <= '\r' },
	"blank": func(c rune) bool { return c == ' ' || c == '\t' },
	"punct": func(c rune) bool {
		return c > ' ' && c < 0x7f && !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9')
	},
	"xdigit": func(c rune) bool { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' },
}
