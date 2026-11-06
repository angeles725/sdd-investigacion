package toolcatalog

// inRegistry is `grep -qiwF -- tool registry`: whether the fixed string tool occurs, case-insensitively and as a
// whole word, on any line of lines.
func (l locale) inRegistry(lines []string, tool string) bool {
	for _, line := range lines {
		if l.hasWord(line, tool) {
			return true
		}
	}
	return false
}

// hasWord reports an occurrence of pat in line that is not glued to a word constituent on either side. A rejected
// occurrence is followed by a search at the next character, as grep -w does.
func (l locale) hasWord(line, pat string) bool {
	for i := 0; i < len(line); {
		if n, ok := l.foldPrefix(line[i:], pat); ok && l.wordEdges(line, i, i+n) {
			return true
		}
		_, w := l.next(line, i)
		i += w
	}
	return false
}

// wordEdges is true when neither the character before line[from:] nor the one at to is a word constituent.
func (l locale) wordEdges(line string, from, to int) bool {
	if from > 0 {
		if r, _ := l.last(line[:from]); l.isWord(r) {
			return false
		}
	}
	if to < len(line) {
		if r, _ := l.next(line, to); l.isWord(r) {
			return false
		}
	}
	return true
}

// foldPrefix reports whether s starts with pat, ignoring case, and how many bytes of s that is.
func (l locale) foldPrefix(s, pat string) (int, bool) {
	used := 0
	for p := 0; p < len(pat); {
		if used >= len(s) {
			return 0, false
		}
		a, an := l.next(s, used)
		b, bn := l.next(pat, p)
		if !l.sameLetter(a, b) {
			return 0, false
		}
		used += an
		p += bn
	}
	return used, true
}
