package cleancheck

import (
	"os"
	"strconv"
	"testing"
)

// scenario is one differential case: it builds a world, names the arguments (and the environment) the frozen script
// and Check are both given, and the exit code the case is about (a case that exits otherwise proves nothing).
type scenario struct {
	name  string
	build func(w *world)
	args  func(w *world) []string
	env   func(w *world) []string
	want  int
	root  bool // needs a non-root user (a permission case)
	// unordered compares the legacy side as a set of lines: the script's find reports in readdir order, which differs
	// between filesystems and hosts (kit lesson L94); the golden pins the engine's sorted order.
	unordered bool
}

// std is the argument list of a plain run: the repository and its tmp directory.
func std(extra ...string) func(w *world) []string {
	return func(w *world) []string { return append([]string{"--target", w.repo, "--tmp", w.tmp}, extra...) }
}

// stdW is std with arguments that name world paths.
func stdW(extra func(w *world) []string) func(w *world) []string {
	return func(w *world) []string { return append([]string{"--target", w.repo, "--tmp", w.tmp}, extra(w)...) }
}

// keep writes <repo>/.research-sdd/keep.txt.
func keep(w *world, body string) { w.write(".research-sdd/keep.txt", body) }

func scenarios() []scenario {
	var all []scenario
	for _, g := range [][]scenario{scanScenarios(), tmpScenarios(), scratchScenarios(), worktreeScenarios(), branchScenarios(), evidenceScenarios(), refusalScenarios()} {
		all = append(all, g...)
	}
	return all
}

func uidPlusOne() string { return strconv.Itoa(os.Getuid() + 1) }

// runScenario reports whether this case may run here.
func (sc scenario) skip(t *testing.T) bool {
	if sc.root && os.Getuid() == 0 {
		t.Skip("a permission case needs a non-root user")
		return true
	}
	return false
}
