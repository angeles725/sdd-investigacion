package goimpact_test

import (
	"strings"
	"testing"
)

func TestShimLinesAndClosure(t *testing.T) {
	r := run("--repo", repo(t, nil), mod+"internal/alpha/alpha.go")
	if r.rc != 0 {
		t.Fatalf("%+v", r)
	}
	want := []string{
		"SHIM\t" + mod + "internal/alpha/alpha.go\tresearch-sdd/toolbelt/a.sh\tg one",
		"SHIM\t" + mod + "internal/alpha/alpha.go\tresearch-sdd/toolbelt/tests/x.test.sh\tg one",
		// alpha + commands + cmd/rsdd; one command (g one)
		"CLOSURE\t" + mod + "internal/alpha/alpha.go\t3\t1",
	}
	if strings.Join(r.lines(), "\n") != strings.Join(want, "\n") {
		t.Errorf("got:\n%s", r.out)
	}
}

func TestEveryListPositionResolves(t *testing.T) {
	r := run("--repo", repo(t, nil), mod+"internal/beta/beta.go")
	for _, w := range []string{
		"SHIM\t" + mod + "internal/beta/beta.go\tresearch-sdd/toolbelt/b1.sh\tb first",
		"SHIM\t" + mod + "internal/beta/beta.go\tresearch-sdd/toolbelt/b2.sh\tb mid",
		"SHIM\t" + mod + "internal/beta/beta.go\tresearch-sdd/toolbelt/b3.sh\tb last",
		"CLOSURE\t" + mod + "internal/beta/beta.go\t3\t3",
	} {
		if !has(r.lines(), w) {
			t.Errorf("missing %q in:\n%s", w, r.out)
		}
	}
}

func TestTestOnlyImporterTestFileAndTestdataAreNone(t *testing.T) {
	r := run("--repo", repo(t, nil), mod+"internal/testonly/t.go", mod+"internal/alpha/alpha_test.go", mod+"internal/alpha/testdata/in.txt")
	want := []string{
		"NONE\t" + mod + "internal/testonly/t.go\tgo-test-only",
		"NONE\t" + mod + "internal/alpha/alpha_test.go\tgo-test-only",
		"NONE\t" + mod + "internal/alpha/testdata/in.txt\tgo-test-only",
	}
	if strings.Join(r.lines(), "\n") != strings.Join(want, "\n") || r.rc != 0 {
		t.Errorf("%+v", r)
	}
}

func TestTestdataNamedByBashIsFull(t *testing.T) {
	root := repo(t, map[string]string{"research-sdd/toolbelt/c.sh": "cat internal/alpha/testdata/in.txt\n"})
	r := run("--repo", root, mod+"internal/alpha/testdata/in.txt")
	want := "FULL\t" + mod + "internal/alpha/testdata/in.txt\ttestdata named by bash: research-sdd/toolbelt/c.sh"
	if !has(r.lines(), want) {
		t.Errorf("%+v", r)
	}
}

func TestTypedFullPaths(t *testing.T) {
	cases := map[string]string{
		mod + "go.mod":                        "go.mod",
		mod + "go.sum":                        "go.sum",
		mod + "Makefile":                      "Makefile",
		mod + "cmd/rsdd/main.go":              "cmd",
		mod + "internal/cli/cli.go":           "internal/cli",
		mod + "internal/commands/commands.go": "internal/commands",
		"research-sdd/toolbelt/a.sh":          "outside",
		"../elsewhere/x.go":                   "outside",
		mod + "docs/guide.md":                 "unclassified module file",
		mod + "teeth-debt.txt":                "teeth-debt.txt",
		mod + "internal/alpha/help.txt":       "unclassified module file",
	}
	for f, key := range cases {
		r := run("--repo", repo(t, map[string]string{mod + "go.sum": "", mod + "Makefile": "all:\n", mod + "docs/guide.md": "x", mod + "teeth-debt.txt": "x", mod + "internal/alpha/help.txt": "x"}), f)
		l := r.lines()
		if r.rc != 0 || len(l) == 0 || !strings.HasPrefix(l[0], "FULL\t"+f+"\t") || !strings.Contains(l[0], key) {
			t.Errorf("%s: %+v", f, r)
		}
	}
}

func TestWideClosureIsFullWithSize(t *testing.T) {
	root := repo(t, nil)
	f := mod + "internal/alpha/alpha.go"
	if r := run("--repo", root, "--wide", "1", f); !has(r.lines(), "FULL\t"+f+"\tclosure of 2 bash files is wider than 1") {
		t.Errorf("wide 1: %+v", r)
	}
	if r := run("--repo", root, "--wide", "2", f); strings.Contains(r.out, "FULL") {
		t.Errorf("wide 2 must pass: %+v", r)
	}
}

func TestUnreachedCommandsAreInformationalAtEveryListPosition(t *testing.T) {
	f := mod + "internal/beta/beta.go"
	b := map[string]string{"first": "b1", "mid": "b2", "last": "b3"}
	for cmd, sh := range b {
		root := repo(t, nil, "research-sdd/toolbelt/"+sh+".sh")
		r := run("--repo", root, f)
		l := r.lines()
		if !has(l, "UNREACHED\t"+f+"\tb "+cmd) || strings.Contains(r.out, "FULL") || strings.Contains(r.out, "no-bash-caller") {
			t.Errorf("unreached %s: %+v", cmd, r)
		}
		shims := 0
		for _, x := range l {
			if strings.HasPrefix(x, "SHIM\t") {
				shims++
			}
		}
		if shims != 2 || l[len(l)-1] != "CLOSURE\t"+f+"\t3\t3" {
			t.Errorf("unreached %s: want 2 SHIM lines and a final CLOSURE: %+v", cmd, r)
		}
	}
}

func TestOnlyUnreachedCommandsIsNoBashCaller(t *testing.T) {
	root := repo(t, nil, "research-sdd/toolbelt/b1.sh", "research-sdd/toolbelt/b2.sh", "research-sdd/toolbelt/b3.sh")
	f := mod + "internal/beta/beta.go"
	want := "UNREACHED\t" + f + "\tb first\nUNREACHED\t" + f + "\tb mid\nUNREACHED\t" + f + "\tb last\nNONE\t" + f + "\tno-bash-caller\nCLOSURE\t" + f + "\t3\t3"
	if r := run("--repo", root, f); r.rc != 0 || strings.Join(r.lines(), "\n") != want {
		t.Errorf("%+v", r)
	}
}

func TestBlindSpotIsAddedNeverFull(t *testing.T) {
	root := repo(t, map[string]string{"research-sdd/toolbelt/v.sh": "\"$RSDD_BIN\" \"$grp\" \"$cmd\"\n"})
	f := mod + "internal/alpha/alpha.go"
	r := run("--repo", root, f)
	l := r.lines()
	if !has(l, "BLIND\t"+f+"\tresearch-sdd/toolbelt/v.sh\tC") || !has(l, "SHIM\t"+f+"\tresearch-sdd/toolbelt/a.sh\tg one") || strings.Contains(r.out, "FULL") {
		t.Errorf("%+v", r)
	}
	// a go-test-only file reaches no binary: no BLIND line
	if r := run("--repo", root, mod+"internal/testonly/t.go"); !has(r.lines(), "NONE\t"+mod+"internal/testonly/t.go\tgo-test-only") || strings.Contains(r.out, "BLIND") {
		t.Errorf("%+v", r)
	}
}

// Rule ii: any non-test file built into the binary gets the blind set, command package or not.
func TestBlindSpotsReachEveryFileBuiltIntoTheBinary(t *testing.T) {
	commands := mod + "internal/commands/commands.go"
	extra := map[string]string{
		mod + "internal/noc/n.go": "package noc\n",
	}
	extra[commands] = "package commands\n\nimport (\n\t_ \"example.test/rsdd/internal/noc\"\n\t\"example.test/rsdd/internal/alpha\"\n\t\"example.test/rsdd/internal/beta\"\n\t\"example.test/rsdd/internal/cli\"\n)\n\nvar _ = alpha.Command\nvar _ = beta.Commands\nvar V = cli.Command{Name: \"version\"}\n"
	f := mod + "internal/noc/n.go"
	if r := run("--repo", repo(t, extra), f); strings.Join(r.lines(), "|") != "NONE\t"+f+"\tno-command|CLOSURE\t"+f+"\t3\t0" {
		t.Errorf("no blind spots: %+v", r)
	}
	extra["research-sdd/toolbelt/e.sh"] = "export RSDD_BIN=/x\n"
	r := run("--repo", repo(t, extra), f)
	if !has(r.lines(), "BLIND\t"+f+"\tresearch-sdd/toolbelt/e.sh\tempty-reach") || strings.Contains(r.out, "NONE") || strings.Contains(r.out, "FULL") {
		t.Errorf("blind spots: %+v", r)
	}
}

// The wide threshold counts the SHIM bash files only; blind spots are counted apart.
func TestWideThresholdIgnoresBlindSpots(t *testing.T) {
	root := repo(t, map[string]string{"research-sdd/toolbelt/v1.sh": "echo \"$RSDD_BIN\"\n", "research-sdd/toolbelt/v2.sh": "echo \"$RSDD_BIN\"\n", "research-sdd/toolbelt/v3.sh": "echo \"$RSDD_BIN\"\n"})
	f := mod + "internal/alpha/alpha.go"
	r := run("--repo", root, "--wide", "2", f)
	if strings.Contains(r.out, "FULL") || strings.Count(r.out, "BLIND\t") != 3 {
		t.Errorf("%+v", r)
	}
}

func TestClassesLineIsPrintedOnceAfterTheFileBlocks(t *testing.T) {
	r := run("--repo", repo(t, nil), mod+"internal/alpha/alpha.go", mod+"internal/testonly/t.go")
	want := "CLASSES\tA=0\tB=0\tC=6\tD=0\tunplaceable=0\tempty-reach=0\tblindspot-files=0"
	ls := strings.Split(strings.TrimSuffix(r.out, "\n"), "\n")
	if r.summary() != want || ls[len(ls)-1] != want || strings.Count(r.out, "CLASSES") != 1 {
		t.Errorf("%+v", r)
	}
}

func TestParseErrorAndUnresolvedLiteralAreFull(t *testing.T) {
	f := mod + "internal/alpha/alpha.go"
	bad := repo(t, map[string]string{mod + "internal/util/util.go": "package util\nfunc (\n"})
	if r := run("--repo", bad, f); !strings.Contains(r.out, "FULL\t"+f+"\tparse error: internal/util/util.go") {
		t.Errorf("parse: %+v", r)
	}
	unres := repo(t, map[string]string{mod + "internal/util/c.go": "package util\n\nimport \"example.test/rsdd/internal/cli\"\n\nvar N = \"x\"\nvar C = cli.Command{Name: N}\n"})
	if r := run("--repo", unres, f); !strings.Contains(r.out, "FULL\t"+f+"\tunresolved command literal at internal/util/c.go:6") {
		t.Errorf("unresolved: %+v", r)
	}
}

func TestDegradedAndUsage(t *testing.T) {
	empty := t.TempDir()
	if r := run("--repo", empty, mod+"internal/x.go"); r.rc != 2 || !strings.HasPrefix(r.err, "degraded: go-impact: ") || r.out != "" {
		t.Errorf("no module: %+v", r)
	}
	if r := run("--repo", repo(t, nil)); r.rc != 2 {
		t.Errorf("no files: %+v", r)
	}
	if r := run("--bogus"); r.rc != 2 {
		t.Errorf("bad flag: %+v", r)
	}
	if r := run("--repo", repo(t, nil), "--wide", "0", "x"); r.rc != 2 {
		t.Errorf("wide 0: %+v", r)
	}
}

func TestInputOrderOneBlockPerFile(t *testing.T) {
	root := repo(t, nil)
	r := run("--repo", root, mod+"internal/testonly/t.go", mod+"internal/beta/beta.go", mod+"internal/alpha/alpha_test.go")
	var kinds []string
	for _, l := range r.lines() {
		f := strings.Split(l, "\t")
		kinds = append(kinds, f[0]+" "+f[1][strings.LastIndex(f[1], "/")+1:])
	}
	want := "NONE t.go|SHIM beta.go|SHIM beta.go|SHIM beta.go|CLOSURE beta.go|NONE alpha_test.go"
	if strings.Join(kinds, "|") != want {
		t.Errorf("order: %s", strings.Join(kinds, "|"))
	}
}
