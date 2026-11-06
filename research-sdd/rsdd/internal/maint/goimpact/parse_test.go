package goimpact_test

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

func TestParserRecoversEveryCommandForm(t *testing.T) {
	m, err := goimpact.Load(repo(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, c := range m.AllCommands() {
		got[c.String()] = true
	}
	// single (alpha), first/middle/last of an elided slice (beta), ungrouped (version)
	for _, w := range []string{"g one", "b first", "b mid", "b last", "version"} {
		if !got[w] {
			t.Errorf("command %q not recovered: %v", w, got)
		}
	}
	if len(got) != 5 {
		t.Errorf("want exactly 5 commands, got %v", got)
	}
}

func TestReverseClosureReachesImportersOverNonTestEdgesOnly(t *testing.T) {
	m, err := goimpact.Load(repo(t, nil))
	if err != nil {
		t.Fatal(err)
	}
	// util is imported by alpha, which commands imports, which cmd/rsdd imports
	got := strings.Join(m.ReverseClosure("internal/util"), ",")
	if got != "cmd/rsdd,internal/alpha,internal/commands,internal/util" {
		t.Errorf("util closure: %s", got)
	}
	// testonly is imported only by alpha_test.go: its closure is itself
	if got := strings.Join(m.ReverseClosure("internal/testonly"), ","); got != "internal/testonly" {
		t.Errorf("testonly closure: %s", got)
	}
	// the registry's own version command is not attributed to a closure
	if c := m.ClosureCommands(m.ReverseClosure("internal/alpha")); len(c) != 1 || c[0].String() != "g one" {
		t.Errorf("alpha commands: %v", c)
	}
}

func TestLoadRecordsParseErrorsAndUnresolvedLiterals(t *testing.T) {
	root := repo(t, map[string]string{
		mod + "internal/util/util.go": "package util\nfunc (\n",
		mod + "internal/beta/c.go":    "package beta\n\nimport \"example.test/rsdd/internal/cli\"\n\nvar N = \"x\"\nvar C = cli.Command{Name: N}\n",
	})
	m, err := goimpact.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	if e := m.Pkgs["internal/util"].ParseErrors; len(e) != 1 || !strings.HasPrefix(e[0], "internal/util/util.go: ") {
		t.Errorf("parse errors: %v", e)
	}
	if u := m.Pkgs["internal/beta"].Unresolved; len(u) != 1 || u[0] != "internal/beta/c.go:6" {
		t.Errorf("unresolved: %v", u)
	}
}

func TestLoadRefusesAnUnreadableModule(t *testing.T) {
	if _, err := goimpact.Load(t.TempDir()); err == nil {
		t.Error("an absent module must be an error, never an empty module")
	}
	root := repo(t, map[string]string{mod + "go.mod": "go 1.27\n"})
	if _, err := goimpact.Load(root); err == nil || !strings.Contains(err.Error(), "no module line") {
		t.Errorf("module line missing: %v", err)
	}
}
