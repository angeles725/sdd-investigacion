package probe

// filevercmp is gnulib's filevercmp (coreutils >= 9.0, the `sort -V` key) for names that are neither empty
// nor start with '.', which holds for the absolute paths it orders here: compare without the file
// suffixes first, and with them only on a tie.
func filevercmp(a, b string) int {
	ap, bp := filePrefixLen(a), filePrefixLen(b)
	if r := verrevcmp(a[:ap], b[:bp]); r != 0 || (ap == len(a) && bp == len(b)) {
		return r
	}
	return verrevcmp(a, b)
}

func isDigit(c byte) bool { return '0' <= c && c <= '9' }
func isAlpha(c byte) bool { return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' }

// filePrefixLen is the length of s without its suffix, a run of (\.[A-Za-z~][A-Za-z0-9~]*) at the end.
func filePrefixLen(s string) int {
	prefix := 0
	for i := 0; i < len(s); {
		i++
		prefix = i
		for i+1 < len(s) && s[i] == '.' && (isAlpha(s[i+1]) || s[i+1] == '~') {
			for i += 2; i < len(s) && (isAlpha(s[i]) || isDigit(s[i]) || s[i] == '~'); i++ {
			}
		}
	}
	return prefix
}

// order ranks s[pos] for verrevcmp: end of string and '~' sort first, digits (handled numerically), then
// letters, then every other byte.
func order(s string, pos int) int {
	if pos == len(s) {
		return -1
	}
	switch c := s[pos]; {
	case isDigit(c):
		return 0
	case isAlpha(c):
		return int(c)
	case c == '~':
		return -2
	default:
		return int(c) + 256
	}
}

// verrevcmp is the Debian version comparison: alternating non-digit runs compared by order and digit runs
// compared numerically.
func verrevcmp(a, b string) int {
	i, j := 0, 0
	for i < len(a) || j < len(b) {
		for (i < len(a) && !isDigit(a[i])) || (j < len(b) && !isDigit(b[j])) {
			if ac, bc := order(a, i), order(b, j); ac != bc {
				return ac - bc
			}
			i, j = i+1, j+1
		}
		for i < len(a) && a[i] == '0' {
			i++
		}
		for j < len(b) && b[j] == '0' {
			j++
		}
		first := 0
		for i < len(a) && j < len(b) && isDigit(a[i]) && isDigit(b[j]) {
			if first == 0 {
				first = int(a[i]) - int(b[j])
			}
			i, j = i+1, j+1
		}
		if i < len(a) && isDigit(a[i]) {
			return 1
		}
		if j < len(b) && isDigit(b[j]) {
			return -1
		}
		if first != 0 {
			return first
		}
	}
	return 0
}
