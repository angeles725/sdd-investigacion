package goimpact_test

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

// realRepo is the repository root this source file lives in (research-sdd/rsdd/internal/maint/goimpact).
func realRepo(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate the test source")
	}
	root := filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "..")
	if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(goimpact.ModuleDir), "go.mod")); err != nil {
		t.Skipf("not inside the kit repository: %v", err)
	}
	return root
}

func label(c cli.Command) string { return goimpact.Command{Group: c.Group, Name: c.Name}.String() }

func keys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// C1 (enumerator proof): the commands the parser recovers from cli.Command literals must equal the commands of
// the assembled registry. A registration form the parser cannot see fails here instead of shrinking selections.
func TestParserMatchesAssembledRegistry(t *testing.T) {
	m, err := goimpact.Load(realRepo(t))
	if err != nil {
		t.Fatal(err)
	}
	parsed, registry := map[string]bool{}, map[string]bool{}
	for _, c := range m.AllCommands() {
		parsed[c.String()] = true
	}
	for _, c := range commands.Table {
		registry[label(c)] = true
	}
	if len(registry) < 50 {
		t.Fatalf("registry looks truncated: %d commands", len(registry))
	}
	for _, k := range keys(registry) {
		if !parsed[k] {
			t.Errorf("registry command %q is invisible to the parser", k)
		}
	}
	for _, k := range keys(parsed) {
		if !registry[k] {
			t.Errorf("parser recovered %q which the registry does not contain", k)
		}
	}
	for _, d := range m.Dirs() {
		if u := m.Pkgs[d].Unresolved; len(u) > 0 {
			t.Errorf("unresolved cli.Command literals in %s: %v", d, u)
		}
		if e := m.Pkgs[d].ParseErrors; len(e) > 0 {
			t.Errorf("parse errors in %s: %v", d, e)
		}
	}
}
