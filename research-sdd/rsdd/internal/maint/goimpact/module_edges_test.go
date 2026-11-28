package goimpact_test

import (
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

const cliImp = "package p\n\nimport \"example.test/rsdd/internal/cli\"\n\n"

func TestLoadSkipsOnlyTestdataVendorAndDotDirectories(t *testing.T) {
	cmd := cliImp + "var C = cli.Command{Name: \"x\", Group: \"g\"}\n"
	m, err := goimpact.Load(repo(t, map[string]string{
		mod + "internal/vendor/v.go": cmd, mod + "internal/testdata/t.go": cmd, mod + "internal/.hid/h.go": cmd,
		mod + "internal/testdatax/s.go": cmd, mod + "internal/vend/s.go": cmd, mod + "internal/dot.ted/s.go": cmd,
		mod + "internal/a/vendor/deep.go": cmd,
	}))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range m.Dirs() {
		if strings.HasPrefix(d, "internal/") && !strings.Contains("alpha beta cli util testonly commands", strings.TrimPrefix(d, "internal/")) {
			got = append(got, d)
		}
	}
	sort.Strings(got)
	if want := "internal/dot.ted,internal/testdatax,internal/vend"; strings.Join(got, ",") != want {
		t.Errorf("walked %v, want %s", got, want)
	}
}

func TestImportsKeepOnlyModulePackages(t *testing.T) {
	m, err := goimpact.Load(repo(t, map[string]string{
		mod + "root.go": "package rsdd\n",
		mod + "internal/imp/i.go": "package imp\n\nimport (\n\t_ \"example.test/rsdd\"\n\t_ \"example.test/rsdd/internal/util\"\n" +
			"\t_ \"example.test/rsddx/other\"\n\t_ \"example.test/rsd\"\n\t_ \"fmt\"\n)\n",
	}))
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for d := range m.Pkgs["internal/imp"].Imports {
		got = append(got, "["+d+"]")
	}
	sort.Strings(got)
	if strings.Join(got, ",") != "[],[internal/util]" {
		t.Errorf("imports %v", got)
	}
}

func TestOnlyConstantsWithValuesAreRecovered(t *testing.T) {
	m, err := goimpact.Load(repo(t, map[string]string{
		mod + "internal/k/k.go": cliImp + "const (\n\tG = \"g\"\n\tH\n)\n\nconst P, Q = \"p\"\n\n" +
			"var A = cli.Command{Group: G, Name: \"one\"}\nvar B = cli.Command{Name: P}\nvar C = cli.Command{Name: Q}\n",
	}))
	if err != nil {
		t.Fatal(err)
	}
	var cmds []string
	for _, c := range m.Pkgs["internal/k"].Commands {
		cmds = append(cmds, c.String())
	}
	if got := strings.Join(cmds, ","); got != "g one,p" || len(m.Pkgs["internal/k"].Unresolved) != 1 {
		t.Errorf("commands %q, unresolved %v", got, m.Pkgs["internal/k"].Unresolved)
	}
}

// A bare `testdata` names nothing; the module-relative and tail forms do, also for a file at the module root.
func TestTestdataNamingForms(t *testing.T) {
	f := mod + "internal/alpha/testdata/in.txt"
	cases := []struct{ name, text, file, want string }{
		{"bare word", "uses testdata here\n", f, "NONE\t" + f + "\tgo-test-only"},
		{"tail form", "cat testdata/in.txt\n", f, "FULL\t" + f + "\ttestdata named by bash: research-sdd/toolbelt/c.sh"},
		{"directory", "ls internal/alpha/testdata\n", f, "FULL\t" + f + "\ttestdata named by bash: research-sdd/toolbelt/c.sh"},
		{"other directory", "ls internal/beta/testdata\n", f, "NONE\t" + f + "\tgo-test-only"},
		{"root file", "cat testdata/x.txt\n", mod + "testdata/x.txt", "FULL\t" + mod + "testdata/x.txt\ttestdata named by bash: research-sdd/toolbelt/c.sh"},
		{"root file unnamed", "echo nothing\n", mod + "testdata/x.txt", "NONE\t" + mod + "testdata/x.txt\tgo-test-only"},
	}
	for _, c := range cases {
		r := run("--repo", repo(t, map[string]string{tb + "c.sh": c.text}), c.file)
		if !has(r.lines(), c.want) {
			t.Errorf("%s: %q", c.name, r.lines())
		}
	}
}

func TestParseErrorPicksTheFirstProblemOnly(t *testing.T) {
	root := repo(t, map[string]string{
		mod + "internal/beta/bad.go": "package beta\nfunc (\n",
		mod + "internal/beta/c.go":   cliImp + "var N = \"x\"\nvar C = cli.Command{Name: N}\n",
	})
	r := run("--repo", root, mod+"internal/alpha/alpha.go")
	if l := r.lines(); len(l) != 1 || !strings.HasPrefix(l[0], "FULL\t"+mod+"internal/alpha/alpha.go\tparse error: internal/beta/bad.go: ") {
		t.Errorf("%q", l)
	}
	root = repo(t, map[string]string{mod + "internal/beta/c.go": cliImp + "var N = \"x\"\nvar C = cli.Command{Name: N}\n"})
	r = run("--repo", root, mod+"internal/alpha/alpha.go")
	if l := r.lines(); len(l) != 1 || !strings.Contains(l[0], "unresolved command literal at internal/beta/c.go:") {
		t.Errorf("%q", l)
	}
}
