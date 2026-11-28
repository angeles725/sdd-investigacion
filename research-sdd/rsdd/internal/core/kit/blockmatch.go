package kit

import "strings"

// The hand-written twin of the block-file regexp (kit issue #2686). The POSIX regexp of FilterBlockFiles runs on
// every file name of a corpus (thousands, for the largest one), several times per run; for the two shapes of
// pattern the kit actually uses it is a few byte comparisons. TestFastBlockMatcherAgreesWithRegexp pins the
// twin to the regexp; the regexp stays the definition (blockfiles.go) and decides every other prefix.
//
// Why the last path element decides: no part of the pattern after its `(^|/)` anchor can hold a '/', and `$` ends
// the line, so a match lies wholly in the part after the last '/' (the whole line when there is none).

// fastBlockMatcher is the matcher FilterBlockFiles uses for prefix, or nil when only the regexp can decide: an empty
// prefix is `(^|/)[^/]+-TAIL`, a prefix of plain ERE literals is `(^|/)PREFIX TAIL`.
func fastBlockMatcher(prefix string) func(string) bool {
	switch {
	case prefix == "":
		return matchBlockName
	case isLiteralPrefix(prefix):
		return func(l string) bool { return matchPrefixedBlock(l, prefix) }
	}
	return nil
}

// isLiteralPrefix reports whether a focus prefix is plain ERE literals ([A-Za-z0-9_-] only).
func isLiteralPrefix(p string) bool {
	for i := 0; i < len(p); i++ {
		if c := p[i]; !isSlugByte(c) {
			return false
		}
	}
	return true
}

// isSlugByte is [[:alnum:]_-] in the C locale.
func isSlugByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// lastElement is the part of a path after its last '/'.
func lastElement(l string) string { return l[strings.LastIndexByte(l, '/')+1:] }

// matchBlockName is reBlock.MatchString: some '-' with at least one byte before it and the block tail after it.
func matchBlockName(l string) bool {
	name, ok := strings.CutSuffix(lastElement(l), ".md")
	if !ok {
		return false
	}
	for i := 1; i < len(name); i++ {
		if name[i] == '-' && matchBlockTail(name[i+1:]) {
			return true
		}
	}
	return false
}

// matchPrefixedBlock is the regexp of FilterBlockFiles for a literal prefix: the last element starts with the prefix.
func matchPrefixedBlock(l, prefix string) bool {
	rest, ok := strings.CutPrefix(lastElement(l), prefix)
	if !ok {
		return false
	}
	name, ok := strings.CutSuffix(rest, ".md")
	return ok && matchBlockTail(name)
}

// matchBlockTail is the tail of blockTail over the whole of s, its ".md" already cut: the kind (block or bloque),
// one or more digits, then optionally a dash and one or more slug bytes. The
// digits are taken greedily: a shorter run would leave a digit where only "-" or the end may follow.
func matchBlockTail(s string) bool {
	switch {
	case strings.HasPrefix(s, "bloque"):
		s = s[len("bloque"):]
	case strings.HasPrefix(s, "block"):
		s = s[len("block"):]
	default:
		return false
	}
	n := 0
	for n < len(s) && s[n] >= '0' && s[n] <= '9' {
		n++
	}
	if n == 0 {
		return false
	}
	s = s[n:]
	if s == "" {
		return true
	}
	if s[0] != '-' || len(s) == 1 {
		return false
	}
	for i := 1; i < len(s); i++ {
		if !isSlugByte(s[i]) {
			return false
		}
	}
	return true
}
