package goimpact_test

import (
	"os"
	"path/filepath"
	"testing"
)

const mod = "research-sdd/rsdd/"

// write puts files (repo-relative slash path -> content) under root.
func write(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for p, c := range files {
		abs := filepath.Join(root, filepath.FromSlash(p))
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(abs, []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// synth is a small module: g one (alpha, imports util), b first/mid/last (beta), version (commands),
// testonly (imported by a test file only), plus bash callers for every command.
func synth() map[string]string {
	imp := `import "example.test/rsdd/internal/cli"` + "\n"
	return map[string]string{
		mod + "go.mod":                          "module example.test/rsdd\n\ngo 1.27\n",
		mod + "internal/cli/cli.go":             "package cli\n\ntype Command struct{ Name, Group string }\n",
		mod + "internal/util/util.go":           "package util\n\nconst X = 1\n",
		mod + "internal/testonly/t.go":          "package testonly\n\nconst T = 1\n",
		mod + "internal/alpha/alpha.go":         "package alpha\n\nimport (\n\t\"example.test/rsdd/internal/cli\"\n\t_ \"example.test/rsdd/internal/util\"\n)\n\nvar Command = cli.Command{Name: \"one\", Group: \"g\"}\n",
		mod + "internal/alpha/alpha_test.go":    "package alpha\n\nimport _ \"example.test/rsdd/internal/testonly\"\n",
		mod + "internal/alpha/testdata/in.txt":  "x\n",
		mod + "internal/beta/beta.go":           "package beta\n\n" + imp + "\nvar Commands = []cli.Command{{Name: \"first\", Group: \"b\"}, {Name: \"mid\", Group: \"b\"}, {Name: \"last\", Group: \"b\"}}\n",
		mod + "internal/commands/commands.go":   "package commands\n\nimport (\n\t\"example.test/rsdd/internal/alpha\"\n\t\"example.test/rsdd/internal/beta\"\n\t\"example.test/rsdd/internal/cli\"\n)\n\nvar _ = alpha.Command\nvar _ = beta.Commands\nvar V = cli.Command{Name: \"version\"}\n",
		mod + "cmd/rsdd/main.go":                "package main\n\nimport _ \"example.test/rsdd/internal/commands\"\n",
		"research-sdd/toolbelt/a.sh":            "#!/usr/bin/env bash\nrsdd_exec g one \"$@\"\n",
		"research-sdd/toolbelt/b1.sh":           "#!/usr/bin/env bash\nrsdd_exec_hook sweep b first --x\n",
		"research-sdd/toolbelt/b2.sh":           "#!/usr/bin/env bash\n\"$RSDD_BIN\" b mid\n",
		"research-sdd/toolbelt/b3.sh":           "#!/usr/bin/env bash\nif ! ${RSDD_REAL_BIN} b last; then :; fi\nrsdd version\n",
		"research-sdd/toolbelt/tests/x.test.sh": "#!/usr/bin/env bash\nout=$(\"${RSDD_BIN}\" g one)\n",
	}
}

// repo builds the synth tree (minus drop, plus extra) in a temp dir and returns its root.
func repo(t *testing.T, extra map[string]string, drop ...string) string {
	t.Helper()
	root := t.TempDir()
	files := synth()
	for _, d := range drop {
		delete(files, d)
	}
	for p, c := range extra {
		files[p] = c
	}
	write(t, root, files)
	return root
}

func has(lines []string, want string) bool {
	for _, l := range lines {
		if l == want {
			return true
		}
	}
	return false
}
