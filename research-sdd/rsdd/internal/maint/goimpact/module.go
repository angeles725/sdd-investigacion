// Package goimpact is `rsdd maint go-impact` (kit issue #2613, PR a): it maps changed files under the rsdd Go
// module to the toolbelt bash files that reach the rsdd commands built from them, so a later change can stop
// suite-impact.sh from sending every Go-only change to the FULL gate.
//
// It is computed from source on every run (go/parser and go/ast only: no `go list`, no build, no generated
// manifest to drift) and fails closed: whatever it cannot place is a FULL line with a typed reason.
//
// Every way bash reaches an rsdd command that the enumerator recognises (surveyed against the real tree, and
// pinned by TestBashEnumeratorMatchesRegistryOnTheRealTree):
//
//	rsdd_exec <group> <name>                       the shim helper (toolbelt/lib/rsdd-exec.sh)
//	rsdd_exec_hook <kind> <group> <name>           the hook flavour of the helper (<kind> is skipped)
//	"$RSDD_BIN" <group> <name>  (also ${RSDD_BIN}) a suite or script calling the binary directly
//	"$RSDD_REAL_BIN" <group> <name>                the same, through the saved real binary
//	rsdd <group> <name>  (also <path>/rsdd)        a literal invocation
//
// A single word after the executable that names an ungrouped command (`rsdd version`) resolves too.
//
// Every RSDD_BIN / RSDD_REAL_BIN mention in code is classified by the bash tokens (rule i'): A assignment,
// export, declare, local, unset or env prefix, and B operand of [ ], [[ ]] or test, are not calls; C command
// position and D argument position after another command word are calls; a mention inside eval, a `bash -c`
// string or an executed here-doc is unplaceable. A C or D mention whose next two words are not a registered group
// and name, and every unplaceable one, makes its file a Go BLIND SPOT, as does a file that mentions the binary
// yet reaches no command at all (`empty-reach`). A blind-spot file is added to the selection of every change
// built into the binary and never makes it FULL; the derived set is pinned by testdata/go-blindspot.txt. The wide
// threshold counts SHIM bash files only: blind spots are one fixed list per run, counted apart.
//
// Non-Go files of the module have an explicit class (C10): go.mod, go.sum, Makefile and teeth-debt.txt are FULL;
// anything under testdata/ is go-test-only unless a bash file names it (FULL); every other one is FULL as an
// `unclassified module file`. A non-Go file is never a member of its package. Deliberately, testdata ->
// go-test-only drops today's basename edges from module testdata to live scripts.
//
// Scope: every *.sh (and extensionless shebang file) under research-sdd outside the rsdd/ module, whose
// scripts are frozen test fixtures, not callers.
package goimpact

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Command is one rsdd command: an empty Group is an ungrouped command such as `version`.
type Command struct{ Group, Name string }

// String is the "group name" form the output prints (just "name" when ungrouped).
func (c Command) String() string {
	if c.Group == "" {
		return c.Name
	}
	return c.Group + " " + c.Name
}

// Package is one directory of the module, keyed by its module-relative slash path ("" is the root).
type Package struct {
	Dir         string
	Imports     map[string]bool // in-module dirs imported by non-test files
	TestImports map[string]bool // in-module dirs imported only by _test.go files
	Commands    []Command       // cli.Command literals with constant Group and Name
	Unresolved  []string        // cli.Command literals the parser cannot read, as file:line
	ParseErrors []string        // non-test files that did not parse
}

// Module is the parsed rsdd Go module.
type Module struct {
	Path string // the module path from go.mod
	Pkgs map[string]*Package
}

// ModuleDir is where the module lives under the repository root.
const ModuleDir = "research-sdd/rsdd"

// Load parses the module under repo. An unreadable module (no go.mod, no module line, a directory that cannot
// be walked) is an error: the caller reports it as degraded, never as an empty module.
func Load(repo string) (*Module, error) {
	root := filepath.Join(repo, filepath.FromSlash(ModuleDir))
	mod, err := readModulePath(filepath.Join(root, "go.mod"))
	if err != nil {
		return nil, err
	}
	m := &Module{Path: mod, Pkgs: map[string]*Package{}}
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		if !d.IsDir() {
			return nil
		}
		if p != root && (d.Name() == "testdata" || d.Name() == "vendor" || strings.HasPrefix(d.Name(), ".")) {
			return filepath.SkipDir
		}
		rel, _ := filepath.Rel(root, p)
		if rel == "." {
			rel = ""
		}
		pkg, perr := parseDir(m, p, filepath.ToSlash(rel))
		if perr != nil {
			return perr
		}
		if pkg != nil {
			m.Pkgs[pkg.Dir] = pkg
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("cannot read the module %s: %w", ModuleDir, err)
	}
	if len(m.Pkgs) == 0 {
		return nil, fmt.Errorf("no Go package found under %s", ModuleDir)
	}
	return m, nil
}

func readModulePath(gomod string) (string, error) {
	b, err := os.ReadFile(gomod)
	if err != nil {
		return "", fmt.Errorf("cannot read %s: %w", gomod, err)
	}
	for _, l := range strings.Split(string(b), "\n") {
		if f := strings.Fields(l); len(f) == 2 && f[0] == "module" {
			return f[1], nil
		}
	}
	return "", fmt.Errorf("%s has no module line", gomod)
}

// Dirs returns the package dirs in sorted order.
func (m *Module) Dirs() []string {
	out := make([]string, 0, len(m.Pkgs))
	for d := range m.Pkgs {
		out = append(out, d)
	}
	sort.Strings(out)
	return out
}

// AllCommands returns every recovered command, in dir then source order.
func (m *Module) AllCommands() []Command {
	var out []Command
	for _, d := range m.Dirs() {
		out = append(out, m.Pkgs[d].Commands...)
	}
	return out
}
