package sizecheck

import (
	"cmp"
	"regexp"
	"slices"
	"strings"
)

// Hotspot thresholds: a file with more than hotShare percent of the authored lines, at least hotMinLines non-blank
// added lines, of which at least hotSame percent are one pattern after normalisation.
const (
	hotShare    = 40
	hotMinLines = 10
	hotSame     = 80
)

// hotspot is a file whose churn is one repeated edit.
type hotspot struct {
	path              string
	lines, pct, share int
	pattern           string
}

var (
	spaceRun  = regexp.MustCompile(`[ \t]+`)
	dquoted   = regexp.MustCompile(`"[^"]*"`)
	squoted   = regexp.MustCompile(`'[^']*'`)
	digitRuns = regexp.MustCompile(`[0-9]+`)
)

// hotspots checks every candidate (a file above hotShare percent) with `git diff --unified=0` and names the ones that
// are one repeated edit. A candidate whose diff failed is returned in unchecked, never read as "no churn".
func hotspots(t tally, rng string, git func(args ...string) (string, bool)) (hs []hotspot, unchecked []string) {
	for _, f := range t.files {
		if f.lines*100 <= t.authored*hotShare {
			continue
		}
		specs := []string{f.path}
		if f.old != "" {
			specs = append(specs, f.old)
		}
		args := append([]string{"--literal-pathspecs", "diff", "--no-ext-diff", "-M", "--unified=0", rng, "--"}, specs...)
		out, ok := git(args...)
		if !ok {
			unchecked = append(unchecked, f.path)
			continue
		}
		total, best, pat := repeated(out)
		if total < hotMinLines || best*100 < total*hotSame {
			continue
		}
		hs = append(hs, hotspot{f.path, f.lines, f.lines * 100 / t.authored, best * 100 / total, pat})
	}
	return hs, unchecked
}

// repeated reads a zero-context diff: the number of non-blank added lines inside hunks, how many of them share the
// most common normalised form, and that form (ties: the smallest, bytewise). Quoted strings become S and digit runs N.
func repeated(diff string) (total, best int, pattern string) {
	counts := map[string]int{}
	inHunk := false
	for _, ln := range strings.Split(diff, "\n") {
		switch {
		case strings.HasPrefix(ln, "diff "):
			inHunk = false
		case strings.HasPrefix(ln, "@@"):
			inHunk = true
		case inHunk && strings.HasPrefix(ln, "+"):
			s := spaceRun.ReplaceAllString(ln[1:], " ")
			s = strings.TrimSuffix(strings.TrimPrefix(s, " "), " ")
			if s == "" {
				continue
			}
			s = dquoted.ReplaceAllString(s, "S")
			s = squoted.ReplaceAllString(s, "S")
			s = digitRuns.ReplaceAllString(s, "N")
			total++
			counts[s]++
		}
	}
	keys := make([]string, 0, len(counts))
	for k := range counts {
		keys = append(keys, k)
	}
	slices.Sort(keys) // bytewise, so the first of the most common forms is the smallest
	if len(keys) == 0 {
		return total, 0, ""
	}
	pattern = slices.MaxFunc(keys, func(a, b string) int { return cmp.Compare(counts[a], counts[b]) })
	return total, counts[pattern], pattern
}
