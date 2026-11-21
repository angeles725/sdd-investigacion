package goimpact_test

import (
	"strings"
	"testing"
)

// Union over build tags: the closure follows every import of every file, whatever its build constraint or
// GOOS/GOARCH suffix, so a package that reaches a command on one platform only still selects that command.
func TestImportsInConstrainedFilesAreInTheClosure(t *testing.T) {
	commands := mod + "internal/commands/commands.go"
	registry := "package commands\n\nimport (\n\t_ \"example.test/rsdd/internal/gamma\"\n\t\"example.test/rsdd/internal/alpha\"\n\t\"example.test/rsdd/internal/cli\"\n)\n\nvar _ = alpha.Command\nvar V = cli.Command{Name: \"version\"}\n"
	base := map[string]string{
		commands:                            registry,
		mod + "internal/q/q.go":             "package q\n\nconst Q = 1\n",
		mod + "internal/gamma/gamma.go":     "package gamma\n\nimport \"example.test/rsdd/internal/cli\"\n\nvar Command = cli.Command{Name: \"two\", Group: \"g\"}\n",
		"research-sdd/toolbelt/gamma-it.sh": "#!/usr/bin/env bash\nrsdd_exec g two\n",
	}
	cases := map[string]struct{ file, src string }{
		"build line":  {"internal/gamma/gamma_tagged.go", "//go:build linux && !nodiff\n\npackage gamma\n\nimport _ \"example.test/rsdd/internal/q\"\n"},
		"GOOS suffix": {"internal/gamma/x_windows.go", "package gamma\n\nimport _ \"example.test/rsdd/internal/q\"\n"},
	}
	q := mod + "internal/q/q.go"
	for name, c := range cases {
		extra := map[string]string{mod + c.file: c.src}
		for k, v := range base {
			extra[k] = v
		}
		r := run("--repo", repo(t, extra), q)
		want := "SHIM\t" + q + "\tresearch-sdd/toolbelt/gamma-it.sh\tg two"
		if !has(r.lines(), want) || strings.Contains(r.out, "go-test-only") {
			t.Errorf("%s: a change in q must reach gamma's command:\n%s", name, r.out)
		}
	}
}
