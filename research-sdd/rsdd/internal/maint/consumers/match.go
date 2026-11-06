package consumers

// countNames counts the whole-name occurrences of names in b (issue #2758, S17): a name is not preceded by a
// letter, a digit, '_', '.' or '-', and not followed by a letter, a digit, '_' or '-', nor by '.' and a letter or
// digit. Letters are ASCII: a non-ASCII byte is a boundary. Every name is made of such characters, so an
// occurrence can only start where a run of them starts and can only end where the run ends or at a '.' that is
// not followed by a letter or digit; that makes the scan one pass over b with a map lookup per candidate end.
func countNames(b []byte, names map[string]bool) map[string]int {
	var counts map[string]int
	hit := func(name []byte) {
		if names[string(name)] {
			if counts == nil {
				counts = map[string]int{}
			}
			counts[string(name)]++
		}
	}
	for i := 0; i < len(b); {
		if !nameByte(b[i]) {
			i++
			continue
		}
		j := i
		for j < len(b) && nameByte(b[j]) {
			j++
		}
		run := b[i:j]
		hit(run)
		for k := 1; k < len(run); k++ {
			if run[k] == '.' && (k+1 == len(run) || !alnum(run[k+1])) {
				hit(run[:k])
			}
		}
		i = j
	}
	return counts
}

func alnum(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

func nameByte(c byte) bool { return alnum(c) || c == '_' || c == '.' || c == '-' }
