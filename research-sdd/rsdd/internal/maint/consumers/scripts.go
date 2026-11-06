package consumers

import (
	"fmt"
	"sort"
	"strings"
)

// scriptSet is the live script list, read from the file list, with what was removed from it.
type scriptSet struct {
	paths     map[string]bool // live script paths
	names     map[string]bool // their basenames
	ambiguous []string        // basenames of two or more live scripts, sorted
	byExt     map[string]int  // extension without the dot to count
	excluded  []int           // per exclusion, parallel to exclusions
	under     int             // files under the script roots, of any kind
}

func findScripts(files []string) scriptSet {
	sc := scriptSet{paths: map[string]bool{}, names: map[string]bool{}, byExt: map[string]int{}, excluded: make([]int, len(exclusions))}
	seen := map[string]int{}
	for _, f := range files {
		if !underRoots(f) {
			continue
		}
		sc.under++
		ext := extOf(f)
		if !scriptExts[ext] {
			continue
		}
		if i := firstExclusion(f); i >= 0 {
			sc.excluded[i]++
			continue
		}
		sc.paths[f] = true
		sc.byExt[strings.TrimPrefix(ext, ".")]++
		seen[baseName(f)]++
	}
	for n, c := range seen {
		sc.names[n] = true
		if c > 1 {
			sc.ambiguous = append(sc.ambiguous, n)
		}
	}
	sort.Strings(sc.ambiguous)
	return sc
}

func underRoots(f string) bool {
	for _, r := range scriptRoots {
		if pathPrefix.holds(f, r) {
			return true
		}
	}
	return false
}

// extOf is the extension of the base name with its dot, or "".
func extOf(f string) string {
	b := baseName(f)
	if i := strings.LastIndexByte(b, '.'); i >= 0 {
		return b[i:]
	}
	return ""
}

func firstExclusion(f string) int {
	for i, e := range exclusions {
		if e.kind.holds(f, e.value) {
			return i
		}
	}
	return -1
}

// extSummary is "sh 133, java 4": by count descending, then by name.
func (sc scriptSet) extSummary() string {
	exts := make([]string, 0, len(sc.byExt))
	for e := range sc.byExt {
		exts = append(exts, e)
	}
	sort.Slice(exts, func(i, j int) bool {
		if sc.byExt[exts[i]] != sc.byExt[exts[j]] {
			return sc.byExt[exts[i]] > sc.byExt[exts[j]]
		}
		return exts[i] < exts[j]
	})
	parts := make([]string, len(exts))
	for i, e := range exts {
		parts[i] = fmt.Sprintf("%s %d", e, sc.byExt[e])
	}
	return strings.Join(parts, ", ")
}

// excludedSummary is "`.test.` in the name 190, ...": every exclusion, zero included.
func (sc scriptSet) excludedSummary() string {
	parts := make([]string, len(exclusions))
	for i, e := range exclusions {
		parts[i] = fmt.Sprintf("%s %d", e.label, sc.excluded[i])
	}
	return strings.Join(parts, ", ")
}
