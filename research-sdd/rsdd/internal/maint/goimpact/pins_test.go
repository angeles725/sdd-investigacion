package goimpact_test

import (
	"strings"
	"testing"
)

const cliPkg = "package %s\n\nimport \"example.test/rsdd/internal/cli\"\n\n"

// wiringRoot has package x (command `g xcmd`, a Hook variable) and package y (no command); wire is the body of
// internal/commands/wire.go after its imports.
func wiringRoot(t *testing.T, wire string) string {
	t.Helper()
	return repo(t, map[string]string{
		mod + "internal/x/x.go":           strings.Replace(cliPkg, "%s", "x", 1) + "var Hook func()\n\nvar Command = cli.Command{Name: \"xcmd\", Group: \"g\"}\n",
		mod + "internal/y/y.go":           "package y\n\nfunc F() {}\n\nvar V = 1\n",
		mod + "internal/commands/wire.go": "package commands\n\nimport (\n\t\"example.test/rsdd/internal/x\"\n\t\"example.test/rsdd/internal/y\"\n)\n\n" + wire,
		"research-sdd/toolbelt/x.sh":      "#!/usr/bin/env bash\nrsdd_exec g xcmd\n",
	})
}

// A seam assignment `x.V = y.F` (an injection: package y runs inside the commands of package x) makes a change
// in y reach x's commands. Pin A1: internal/commands/wire.go does verify.SessionBudgetRunner = budget.RunSession.
func TestInjectionAssignmentReachesTheInjectedDomain(t *testing.T) {
	f := mod + "internal/y/y.go"
	for name, wire := range map[string]string{
		"in init":       "func init() { x.Hook = y.F }\n",
		"package level": "var _ = func() int { x.Hook = y.F; return 0 }()\n",
	} {
		r := run("--repo", wiringRoot(t, wire), f)
		if !has(r.lines(), "SHIM\t"+f+"\tresearch-sdd/toolbelt/x.sh\tg xcmd") || r.rc != 0 {
			t.Errorf("%s: y does not reach x's command:\n%s%s", name, r.out, r.err)
		}
	}
	for name, wire := range map[string]string{
		"constant on the right": "func init() { x.Hook = nil; _ = y.V }\n",
		"comparison":            "func init() { _ = x.Hook == nil }\n",
	} {
		r := run("--repo", wiringRoot(t, wire), f)
		if strings.Contains(r.out, "xcmd") {
			t.Errorf("%s: not an injection, yet reaches x:\n%s", name, r.out)
		}
	}
}

// A file named by a //go:embed pattern belongs to that package: a change reaches its commands even when no
// bash file names the path. Pin A2: internal/gate embeds testdata/mergetrain/help.txt.
func TestEmbeddedFileBelongsToItsPackage(t *testing.T) {
	cases := map[string]struct{ directive, file string }{
		"exact file":  {"//go:embed testdata/help.txt", "testdata/help.txt"},
		"directory":   {"//go:embed testdata", "testdata/deep/help.txt"},
		"glob":        {"//go:embed testdata/*.txt", "testdata/help.txt"},
		"quoted":      {"//go:embed \"other.txt\" \"testdata/help.txt\"", "testdata/help.txt"},
		"all: prefix": {"//go:embed all:testdata", "testdata/.hidden"},
		"plain file":  {"//go:embed help.txt", "help.txt"},
	}
	for name, c := range cases {
		root := repo(t, map[string]string{
			mod + "internal/emb/emb.go":    strings.Replace(cliPkg, "%s", "emb", 1) + "import _ \"embed\"\n\n" + c.directive + "\nvar h string\n\nvar Command = cli.Command{Name: \"embcmd\", Group: \"g\"}\n",
			mod + "internal/emb/" + c.file: "x\n",
			"research-sdd/toolbelt/emb.sh": "#!/usr/bin/env bash\nrsdd_exec g embcmd\n",
		})
		f := mod + "internal/emb/" + c.file
		r := run("--repo", root, f)
		if !has(r.lines(), "SHIM\t"+f+"\tresearch-sdd/toolbelt/emb.sh\tg embcmd") || r.rc != 0 {
			t.Errorf("%s: embedded file does not reach its package's command:\n%s%s", name, r.out, r.err)
		}
	}
	// a testdata file nothing embeds stays go-test-only
	root := repo(t, map[string]string{
		mod + "internal/emb/emb.go":         strings.Replace(cliPkg, "%s", "emb", 1) + "var Command = cli.Command{Name: \"embcmd\", Group: \"g\"}\n",
		mod + "internal/emb/testdata/x.txt": "x\n",
	})
	f := mod + "internal/emb/testdata/x.txt"
	if r := run("--repo", root, f); !has(r.lines(), "NONE\t"+f+"\tgo-test-only") {
		t.Errorf("unembedded testdata:\n%s", r.out)
	}
}
