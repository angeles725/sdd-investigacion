package block

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// Kit issue #2600, shared lesson L29: pin what the port may do beyond reading files (the subprocesses it spawns) and
// prove every typed state it can print is exercised somewhere, so a state nobody tests cannot drift unseen.

// TestBlockSpawnsOnlyGitRevParse replays every golden case while recording each subprocess: the only one the command
// may spawn is `git -C <target> rev-parse --show-toplevel`. Not parallel: it swaps the package seam while the
// parallel tests are paused.
func TestBlockSpawnsOnlyGitRevParse(t *testing.T) {
	var mu sync.Mutex
	var spawned [][]string
	old := gitCommand
	gitCommand = func(name string, arg ...string) *exec.Cmd {
		mu.Lock()
		spawned = append(spawned, append([]string{name}, arg...))
		mu.Unlock()
		return old(name, arg...)
	}
	t.Cleanup(func() { gitCommand = old })
	cases := bkAllCases(t)
	for _, c := range cases {
		_, cwd, args, env := bkMaterialize(t, c)
		bkGo(cwd, args, env)
	}
	t.Logf("%d cases replayed, %d subprocesses recorded", len(cases), len(spawned))
	if len(cases) == 0 || len(spawned) == 0 {
		t.Fatalf("%d cases, %d subprocesses: a recording that saw nothing proves nothing", len(cases), len(spawned))
	}
	for _, argv := range spawned {
		if len(argv) != 5 || argv[0] != "git" || argv[1] != "-C" || argv[3] != "rev-parse" || argv[4] != "--show-toplevel" {
			t.Errorf("unexpected subprocess %q", argv)
		}
	}
}

// TestBlockSpawnsOnlyThroughTheSeam backs the recording above: in this package and every module package it imports,
// blockgit.go is the only file importing os/exec, and no file calls StartProcess, ForkExec or Exec by those names.
// It is a static check of those spellings (not of the standard library, nor of a call through another name).
func TestBlockSpawnsOnlyThroughTheSeam(t *testing.T) {
	root, module := l29Module(t)
	var spawners []string
	seen := map[string]bool{}
	queue := []string{"internal/verify/block"}
	for len(queue) > 0 {
		pkg := queue[0]
		queue = queue[1:]
		if seen[pkg] {
			continue
		}
		seen[pkg] = true
		files, _ := filepath.Glob(filepath.Join(root, pkg, "*.go"))
		for _, f := range files {
			if strings.HasSuffix(f, "_test.go") {
				continue
			}
			af, err := parser.ParseFile(token.NewFileSet(), f, nil, 0)
			if err != nil {
				t.Fatal(err)
			}
			for _, im := range af.Imports {
				p, _ := strconv.Unquote(im.Path.Value)
				if rest, ok := strings.CutPrefix(p, module+"/"); ok {
					queue = append(queue, rest)
				}
				if p == "os/exec" {
					spawners = append(spawners, filepath.ToSlash(strings.TrimPrefix(f, root+"/")))
				}
			}
			ast.Inspect(af, func(n ast.Node) bool {
				if sel, ok := n.(*ast.SelectorExpr); ok && slices.Contains([]string{"StartProcess", "ForkExec", "Exec"}, sel.Sel.Name) {
					t.Errorf("%s calls %s", f, sel.Sel.Name)
				}
				return true
			})
		}
	}
	t.Logf("%d packages scanned", len(seen))
	if len(seen) < 2 || !slices.Equal(spawners, []string{"internal/verify/block/blockgit.go"}) {
		t.Errorf("%d packages scanned; files importing os/exec: %q, want only internal/verify/block/blockgit.go", len(seen), spawners)
	}
}

// l29Module is the module root (three levels above this package) and the module path its go.mod declares.
func l29Module(t *testing.T) (root, module string) {
	t.Helper()
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(root, "go.mod"))
	if err != nil {
		t.Fatal(err)
	}
	first, _, _ := strings.Cut(string(b), "\n")
	module, ok := strings.CutPrefix(first, "module ")
	if !ok {
		t.Fatalf("go.mod does not start with a module line: %q", first)
	}
	return root, strings.TrimSpace(module)
}
