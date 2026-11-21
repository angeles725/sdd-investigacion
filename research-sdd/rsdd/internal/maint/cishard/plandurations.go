package cishard

import (
	"fmt"
	"strconv"
	"strings"
)

// durations is a parsed durations file.
type durations struct {
	weights map[string]int // package -> seconds, for the packages that are planned
	stale   []string       // entries naming no planned package: ignored, named
	invalid []string       // one detail per invalid line, in line order
}

// validSeconds is the grammar of suite-durations.txt: a positive integer of at most six digits, no leading zero.
func validSeconds(s string) bool {
	if len(s) < 1 || len(s) > 6 || s[0] == '0' {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// parseDurations reads "<package> <seconds>" lines, strictly like run-all.sh reads suite-durations.txt: '#' comments and
// blank lines are skipped; a line without seconds, with extra text, with seconds outside the grammar, or a package
// listed twice is invalid. An entry that names no planned package is stale (a renamed or removed package costs balance,
// never correctness), not invalid.
func parseDurations(data []byte, known map[string]bool) durations {
	d := durations{weights: map[string]int{}}
	seen := map[string]bool{}
	for i, raw := range strings.Split(string(data), "\n") {
		line := trimBlank(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := fieldsBlank(line)
		n := i + 1
		if len(f) == 1 {
			d.invalid = append(d.invalid, fmt.Sprintf("line %d: %q has no seconds", n, f[0]))
		} else if len(f) > 2 {
			d.invalid = append(d.invalid, fmt.Sprintf("line %d: %q has extra text after the seconds", n, f[0]))
		} else if !validSeconds(f[1]) {
			d.invalid = append(d.invalid, fmt.Sprintf("line %d: %q has seconds %q (need a positive integer, at most 999999)", n, f[0], f[1]))
		} else if seen[f[0]] {
			d.invalid = append(d.invalid, fmt.Sprintf("line %d: %q is listed twice", n, f[0]))
		} else if !known[f[0]] {
			seen[f[0]] = true
			d.stale = append(d.stale, f[0])
		} else {
			seen[f[0]] = true
			sec, _ := strconv.Atoi(f[1])
			d.weights[f[0]] = sec
		}
	}
	return d
}
