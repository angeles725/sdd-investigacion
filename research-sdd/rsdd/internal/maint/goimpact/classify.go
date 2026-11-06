package goimpact

import (
	"fmt"
	"path"
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
	unclass []string             // bash paths with an exec form no command explains, sorted
}

// NewAnalysis indexes the callers of every command. wide is the FULL threshold in distinct bash files.
func NewAnalysis(m *Module, bash []BashFile, wide int) *Analysis {
	a := &Analysis{mod: m, bash: bash, wide: wide, callers: map[Command][]string{}}
	for _, f := range bash { // bash is sorted by path, so each caller list is too
		for _, c := range f.Calls {
			a.callers[c.Cmd] = append(a.callers[c.Cmd], f.Path)
		}
		if len(f.Unclass) > 0 && f.Exempt == "" {
			a.unclass = append(a.unclass, f.Path)
		}
	}
	return a
}

func full(file, reason string) []string { return []string{"FULL\t" + file + "\t" + reason} }

// Classify returns the output lines for one repo-relative changed file. It never returns an empty slice.
func (a *Analysis) Classify(file string) []string {
	rel, why := moduleRel(file)
	if why != "" {
		return full(file, why)
	}
	if why := typedFull(rel); why != "" {
		return full(file, why)
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
	dir := path.Dir(rel)
	if dir == "." {
		dir = ""
	}
	if _, ok := a.mod.Pkgs[dir]; !ok {
		return full(file, "not in a Go package of the module")
	}
	for _, d := range a.mod.Dirs() {
		if e := a.mod.Pkgs[d].ParseErrors; len(e) > 0 {
			return full(file, "parse error: "+e[0])
		}
		if u := a.mod.Pkgs[d].Unresolved; len(u) > 0 {
			return full(file, "unresolved command literal at "+u[0])
		}
	}
	return a.reach(file, dir)
}

// reach turns a package's reverse closure into SHIM lines, or a typed FULL.
func (a *Analysis) reach(file, dir string) []string {
	closure := a.mod.ReverseClosure(dir)
	cmds := a.mod.ClosureCommands(closure)
	if len(cmds) == 0 {
		for _, d := range closure {
			if d == Registry {
				return full(file, "reaches the registry but defines no command in its closure")
			}
		}
		return []string{"NONE\t" + file + "\tgo-test-only"}
	}
	closureLine := fmt.Sprintf("CLOSURE\t%s\t%d\t%d", file, len(closure), len(cmds))
	distinct := map[string]bool{}
	var shims, unreached []string
	for _, c := range cmds {
		if len(a.callers[c]) == 0 { // C2: the enumerator sees every form, so no toolbelt suite reaches it
			unreached = append(unreached, "UNREACHED\t"+file+"\t"+c.String())
			continue
		}
		for _, b := range a.callers[c] {
			distinct[b] = true
			shims = append(shims, "SHIM\t"+file+"\t"+b+"\t"+c.String())
		}
	}
	if len(a.unclass) > 0 {
		return append(full(file, "unclassifiable bash caller: "+a.unclass[0]), closureLine)
	}
	if len(distinct) > a.wide {
		return append(full(file, fmt.Sprintf("closure of %d bash files is wider than %d", len(distinct), a.wide)), closureLine)
	}
	out := append(shims, unreached...)
	if len(shims) == 0 {
		out = append(out, "NONE\t"+file+"\tno-bash-caller")
	}
	return append(out, closureLine)
}

// namedByBash returns the first bash file (by path) whose text names the testdata file or one of its
// directories below testdata/: by module-relative path (`internal/x/testdata/sub`) or by the `testdata/sub`
// tail. A bare `testdata` is too generic to count as naming anything.
func (a *Analysis) namedByBash(rel string) string {
	segs := strings.Split(rel, "/")
	ti := -1
	for i, s := range segs {
		if s == "testdata" {
			ti = i
			break
		}
	}
	if ti < 0 {
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
