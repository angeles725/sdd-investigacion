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
