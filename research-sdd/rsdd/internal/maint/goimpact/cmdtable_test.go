package goimpact_test

import (
	"fmt"
	"strings"
	"testing"
)

const aggHead = "package agg\n\nimport (\n\t\"example.test/rsdd/internal/agg/s1\"\n\t\"example.test/rsdd/internal/agg/s2\"\n\t\"example.test/rsdd/internal/agg/s3\"\n\t\"example.test/rsdd/internal/cli\"\n)\n\n" +
	"var _, _, _ = s1.Commands, s2.Commands, s3.Commands\n\nvar local []cli.Command\n\nvar localCmd cli.Command\n\n"

// aggRoot is a module whose agg package assembles its table from three sub-packages (s1, s2, s3), each with
// one command called by one bash file; body is the rest of agg/commands.go after aggHead.
func aggRoot(t *testing.T, body string) string {
	t.Helper()
	files := map[string]string{mod + "internal/agg/commands.go": aggHead + body}
	for _, n := range []string{"s1", "s2", "s3"} {
		files[mod+"internal/agg/"+n+"/"+n+".go"] = "package " + n + "\n\nimport \"example.test/rsdd/internal/cli\"\n\n" +
			"var Commands = []cli.Command{{Name: \"" + n + "\", Group: \"agg\"}}\nvar Command = Commands[0]\nvar Tables = []string{}\n"
		files["research-sdd/toolbelt/"+n+".sh"] = "#!/usr/bin/env bash\nrsdd_exec agg " + n + "\n"
	}
	return repo(t, files)
}

const aggFile = mod + "internal/agg/commands.go"

func shimFor(n string) string {
	return "SHIM\t" + aggFile + "\tresearch-sdd/toolbelt/" + n + ".sh\tagg " + n
}

func wantAll(t *testing.T, name string, r result, ns ...string) {
	t.Helper()
	for _, n := range ns {
		if !has(r.lines(), shimFor(n)) {
			t.Errorf("%s: no %s:\n%s%s", name, shimFor(n), r.out, r.err)
		}
	}
	if strings.Contains(r.out, "FULL\t") || r.rc != 0 {
		t.Errorf("%s: unexpected FULL or exit %d:\n%s", name, r.rc, r.out)
	}
}

// A readable reference in FIRST, MIDDLE and LAST position of a literal table, of an append call, and a
// single-element table, each reaches every referenced package's command (verifier B1).
func TestReadableTablesReachEveryReference(t *testing.T) {
	refs := []string{"s1.Commands", "s2.Commands", "s3.Commands"}
	cases := map[string]string{}
	for i := range refs {
		pos := func(sep, other string) string {
			parts := []string{other, other, other}
			parts[i] = refs[i]
			return strings.Join(parts, sep)
		}
		cases[fmt.Sprintf("literal elements, position %d", i)] = "var Commands = []cli.Command{" + strings.ReplaceAll(pos(", ", "localCmd"), ".Commands", ".Command") + "}\n"
		cases[fmt.Sprintf("append, position %d", i)] = "var Commands = append(" + pos(", ", "local") + ")\n"
	}
	cases["single literal element"] = "var Commands = []cli.Command{s2.Command}\n"
	cases["single append"] = "var Commands = append([]cli.Command(nil), s2.Commands...)\n"
	cases["alias of a table"] = "var Commands = s2.Commands\n"
	cases["parenthesised"] = "var Commands = (s2.Commands)\n"
	cases["init assignment"] = "var Commands []cli.Command\n\nfunc init() { Commands = append(Commands, s2.Commands...) }\n"
	for name, body := range cases {
		r := run("--repo", aggRoot(t, body), aggFile)
		var want []string
		for _, n := range []string{"s1", "s2", "s3"} {
			if strings.Contains(body, n+".Command") {
				want = append(want, n)
			}
		}
		wantAll(t, name, r, want...)
	}
}

// A table the parser cannot read is FULL for every change and its reason names file, line and expression.
func TestUnreadableTableIsFullNamingFileAndExpression(t *testing.T) {
	cases := map[string][2]string{
		"wrapper call":      {"func wrap(c []cli.Command) []cli.Command { return c }\n\nvar Commands = wrap(s1.Commands)\n", "wrap(s1.Commands)"},
		"index":             {"var Commands = s1.Tables[0]\n", "s1.Tables[0]"},
		"init from a call":  {"var Commands []cli.Command\n\nfunc build() []cli.Command { return nil }\n\nfunc init() { Commands = build() }\n", "build()"},
		"typed var, call":   {"func build() []cli.Command { return nil }\n\nvar Table []cli.Command = build()\n", "build()"},
		"type in the init":  {"func wrap(c []cli.Command) []cli.Command { return c }\n\nvar other = wrap([]cli.Command{})\n", "wrap([]cli.Command{})"},
		"method call":       {"var Commands = local.Merge(s1.Commands)\n", "local.Merge(s1.Commands)"},
		"func literal":      {"var Commands = func() []cli.Command { return nil }()\n", "func() []cli.Command"},
		"ident not a table": {"func build() []cli.Command { return nil }\n\nvar made = build()\n\nvar Commands = made\n", ": made"},
	}
	for name, c := range cases {
		root := aggRoot(t, c[0])
		f := mod + "internal/util/util.go"
		r := run("--repo", root, f)
		prefix := "FULL\t" + f + "\tunresolved command literal at internal/agg/commands.go:"
		if !strings.Contains(r.out, prefix) || !strings.Contains(r.out, c[1]) || r.rc != 0 {
			t.Errorf("%s: want FULL naming file and %q:\n%s%s", name, c[1], r.out, r.err)
		}
	}
}
