package goimpact

import "sort"

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
	for _, d := range closure {
		if d == Registry {
			continue
		}
		for _, c := range m.Pkgs[d].Commands {
			if !seen[c] {
				seen[c] = true
				out = append(out, c)
			}
		}
	}
	return out
}
