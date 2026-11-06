package goimpact

import (
	"path"
	"slices"
	"sort"
	"strings"
)

// DefaultWide is the widest closure (in distinct bash files) that still selects shims instead of FULL.
const DefaultWide = 12

// Analysis classifies changed files against one parsed module and one bash enumeration.
type Analysis struct {
	mod     *Module
	bash    []BashFile
	wide    int
	callers map[Command][]string // command -> sorted bash paths that reach it
	blind   []BashFile           // Go blind spots (not exempt), sorted by path
	counts  Counts
}

// NewAnalysis indexes the callers of every command. wide is the FULL threshold in distinct bash files.
func NewAnalysis(m *Module, bash []BashFile, wide int) *Analysis {
	a := &Analysis{mod: m, bash: bash, wide: wide, callers: map[Command][]string{}}
	for _, f := range bash { // bash is sorted by path, so each caller list is too
		for _, c := range f.Calls {
			a.callers[c.Cmd] = append(a.callers[c.Cmd], f.Path)
		}
		if f.Blind() != "" {
			a.blind = append(a.blind, f)
		}
	}
	a.counts = CountClasses(bash)
	return a
}

func full(file, reason string) []string { return []string{"FULL\t" + file + "\t" + reason} }

// Summary is the aggregate CLASSES line over the whole scanned bash tree.
func (a *Analysis) Summary() string { return a.counts.Line() }

// Classify returns the output lines for one repo-relative changed file. It never returns an empty slice.
func (a *Analysis) Classify(file string) []string {
	rel, why := moduleRel(file)
	if why != "" {
		return full(file, why)
	}
	if why := typedFull(rel); why != "" {
		return full(file, why)
	}
	if owner, ok := a.mod.EmbedOwner(rel); ok && !strings.HasSuffix(rel, ".go") { // an embedded file is its package's
		if script := a.namedByBash(rel); script != "" {
			return full(file, "testdata named by bash: "+script)
		}
		if why := a.mod.firstProblem(); why != "" {
			return full(file, why)
		}
		return a.reach(file, owner)
	}
	if isTestPath(rel) {
		if script := a.namedByBash(rel); script != "" {
			return full(file, "testdata named by bash: "+script)
		}
		return []string{"NONE\t" + file + "\tgo-test-only"}
	}
	if !strings.HasSuffix(rel, ".go") { // a non-Go module file is never a member of its package (C10)
		return full(file, "unclassified module file")
	}
	dir, _ := path.Split(rel)
	dir = strings.TrimSuffix(dir, "/")
	if _, ok := a.mod.Pkgs[dir]; !ok {
		return full(file, "not in a Go package of the module")
	}
	if why := a.mod.firstProblem(); why != "" {
		return full(file, why)
	}
	return a.reach(file, dir)
}

// firstProblem is the reason the parse cannot be trusted (the first parse error, else the first command
// literal that is not constant) in the first package that has one, or "".
func (m *Module) firstProblem() string {
	for _, d := range m.Dirs() {
		for _, e := range m.Pkgs[d].ParseErrors {
			return "parse error: " + e
		}
		for _, u := range m.Pkgs[d].Unresolved {
			return "unresolved command literal at " + u
		}
	}
	return ""
}

// namedByBash returns the first bash file (by path) whose text names the testdata file or one of its
// directories below testdata/: by module-relative path (`internal/x/testdata/sub`) or by the `testdata/sub`
// tail. A bare `testdata` is too generic to count as naming anything.
func (a *Analysis) namedByBash(rel string) string {
	segs := strings.Split(rel, "/")
	ti := slices.Index(segs, "testdata")
	if ti == -1 {
		return ""
	}
	var needles []string
	for k := ti; k < len(segs); k++ {
		needles = append(needles, strings.Join(segs[:k+1], "/"))
		if k > ti {
			needles = append(needles, strings.Join(segs[ti:k+1], "/"))
		}
	}
	sort.Strings(needles)
	for _, f := range a.bash {
		for _, n := range needles {
			if strings.Contains(f.Text, n) {
				return f.Path
			}
		}
	}
	return ""
}
