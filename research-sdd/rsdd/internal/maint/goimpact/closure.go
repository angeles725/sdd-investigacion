package goimpact

import (
	"maps"
	"slices"
	"sort"
)

// Registry is the package that assembles the command table; reaching it means reaching the binary.
const Registry = "internal/commands"

// BinaryPkg is the main package; a package whose reverse closure holds it is built into the binary.
const BinaryPkg = "cmd/rsdd"

// ReverseClosure returns dir plus every package that imports it, directly or transitively, over NON-TEST
// import edges only, sorted. A package reached only through _test.go imports is not in the result.
func (m *Module) ReverseClosure(dir string) []string {
	rev := map[string][]string{}
	for d, p := range m.Pkgs {
		for imp := range p.Imports {
			rev[imp] = append(rev[imp], d)
		}
	}
	seen := map[string]bool{dir: true}
	queue := []string{dir}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, up := range rev[cur] {
			if !seen[up] {
				seen[up] = true
				queue = append(queue, up)
			}
		}
	}
	out := make([]string, 0, len(seen))
	for d := range seen {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

// ClosureCommands returns the commands defined by the packages of a closure, de-duplicated and in order. The
// registry package is skipped: its `version` command sits in every closure, and a change in the registry
// itself is FULL before this is asked.
func (m *Module) ClosureCommands(closure []string) []Command {
	seen := map[Command]bool{}
	var out []Command
	visited := map[string]bool{}
	var add func(d string)
	add = func(d string) { // a package's own commands, then those of the packages its slices reference
		p := m.Pkgs[d]
		if visited[d] || p == nil {
			return
		}
		visited[d] = true
		for _, c := range p.Commands {
			if !seen[c] {
				seen[c] = true
				out = append(out, c)
			}
		}
		for _, r := range slices.Sorted(maps.Keys(p.Refs)) {
			add(r)
		}
	}
	for _, d := range closure {
		if d != Registry {
			add(d)
		}
		for _, x := range slices.Sorted(maps.Keys(m.Injects[d])) { // a seam wires d into x's commands
			if x != Registry {
				add(x)
			}
		}
	}
	return out
}
