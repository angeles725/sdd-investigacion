package goimpact_test

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

// Both sides of each bash boundary, through the public scan: shape is the mentions, calls the resolved edges.
func TestBashBoundariesThroughTheScan(t *testing.T) {
	cases := []struct{ name, src, shape, calls string }{
		{"comment line", `# "$RSDD_BIN" g one`, "", ""},
		{"trailing comment", `"$RSDD_BIN" g one # x`, "C+", "g one"},
		{"hash inside a word", `echo a#b "$RSDD_BIN" g one`, "D+", "g one"},
		{"separator ;", `echo x;"$RSDD_BIN" g one`, "C+", "g one"},
		{"separator |", `echo x|"$RSDD_BIN" g one`, "C+", "g one"},
		{"separator &", `echo x&"$RSDD_BIN" g one`, "C+", "g one"},
		{"separator (", `echo x("$RSDD_BIN" g one)`, "C+", "g one"},
		{"separator )", `echo x)"$RSDD_BIN" g one`, "C+", "g one"},
		{"separator {", `echo x{"$RSDD_BIN" g one}`, "C+", "g one"},
		{"separator }", `echo x}"$RSDD_BIN" g one`, "C+", "g one"},
		{"tab", "echo\t\"$RSDD_BIN\" g one", "D+", "g one"},
		{"escaped separator in quotes", `echo "a\" ; $RSDD_BIN" g one`, "D+", "g one"},
		{"single quotes hide a substitution", `echo '$("$RSDD_BIN" g one)'`, "D-", ""},
		{"closed brace", `${RSDD_BIN} g one`, "C+", "g one"},
		{"unclosed brace", `${RSDD_BIN g one`, "C-", ""},
		{"continuation at the end", "echo x\n\"$RSDD_BIN\" g one\\", "C+", "g one"},
		{"backtick body", "x=`\"$RSDD_BIN\" g one`", "C+", "g one"},
		{"escaped backtick in a body", "x=`echo \\` \"$RSDD_BIN\" g one`", "D+", "g one"},
		{"unclosed backtick", "x=`\"$RSDD_BIN\" g one", "unplaceable", ""},
		{"unclosed substitution without the binary", "x=$(date", "", ""},
		{"paren inside single quotes", `x=$(echo ')' "$RSDD_BIN" g one)`, "D+", "g one"},
		{"unclosed single quote in a body", `x=$(echo ' "$RSDD_BIN" g one)`, "unplaceable", ""},
		{"export with arguments", `export RSDD_BIN g one`, "A", ""},
		{"test operand with arguments", `[ "$RSDD_BIN" g one ]`, "B", ""},
		{"rsdd path form", `/x/bin/rsdd g one`, "C+", "g one"},
		{"function definition", `rsdd_exec() { :; }`, "", ""},
		{"bare rsdd_exec", `rsdd_exec`, "C-", ""},
		{"bare hook", `rsdd_exec_hook`, "C-", ""},
		{"hook with the kind only", `rsdd_exec_hook k`, "C-", ""},
		{"hook with all words", `rsdd_exec_hook k g one`, "C+", "g one"},
		{"bash -x script", `bash -x "$RSDD_BIN" g one`, "D+", "g one"},
		{"bash --rcfile script", `bash --rcfile x "$RSDD_BIN" g one`, "D+", "g one"},
		{"flag after the mention", `bash "$RSDD_BIN" -c`, "D-", ""},
		{"bash -lc", `bash -lc "$RSDD_BIN g one"`, "unplaceable", ""},
	}
	files := map[string]string{}
	for i, c := range cases {
		files[tb+"e"+string(rune('A'+i/26))+string(rune('a'+i%26))+".sh"] = c.src + "\n"
	}
	got := scan(t, files)
	for i, c := range cases {
		f := got["e"+string(rune('A'+i/26))+string(rune('a'+i%26))+".sh"]
		var calls []string
		for _, k := range f.Calls {
			calls = append(calls, k.Cmd.String())
		}
		if shape(f) != c.shape || strings.Join(calls, ",") != c.calls {
			t.Errorf("%s: shape %q calls %q; want %q %q", c.name, shape(f), strings.Join(calls, ","), c.shape, c.calls)
		}
	}
}

// A shim is named only as a whole word, and a file with no mention or with a call is never empty-reach.
func TestEmptyReachBoundaries(t *testing.T) {
	got := scan(t, map[string]string{
		tb + "n1.sh": "export RSDD_BIN=/x\nb1.sh\n", tb + "n2.sh": "export RSDD_BIN=/x\nxb1.sh\n",
		tb + "n3.sh": "export RSDD_BIN=/x\nb1.shx\n", tb + "n4.sh": "export RSDD_BIN=/x\n(b1.sh)\n",
		tb + "n5.sh": "echo no mention here\n", tb + "n6.sh": "export RSDD_BIN=/x\n\"$RSDD_BIN\" g one\n",
	})
	for f, want := range map[string]string{"n1.sh": "", "n2.sh": "empty-reach", "n3.sh": "empty-reach", "n4.sh": "", "n5.sh": "", "n6.sh": ""} {
		if got[f].Blind() != want {
			t.Errorf("%s: blind %q, want %q", f, got[f].Blind(), want)
		}
	}
}

func TestWhichFilesAreBashAndHowBigTheyMayBe(t *testing.T) {
	call := "rsdd_exec g one\n"
	extra := map[string]string{
		tb + "tools/s1": "#!/usr/bin/env bash\n" + call, tb + "tools/s2": "#!/bin/sh\n" + call, tb + "tools/s3": "#!/bin/dash\n" + call,
		tb + "tools/s4": "#!/bin/bash", tb + "tools/n1": "#!/usr/bin/python3\n" + call, tb + "tools/n2": call,
		tb + "tools/n3.py": "#!/bin/bash\n" + call, tb + "tools/s5.sh": call, tb + "tools/n4": "# !/bin/bash\n" + call,
		tb + "tools/n5": " #!/bin/sh\n" + call, tb + "node_modules/n6.sh": call, tb + ".git/n7.sh": call,
		tb + "node_modulesx/s6.sh": call, tb + "gitx/s7.sh": call,
	}
	var got []string
	for _, f := range scanAll(t, extra) {
		if strings.HasPrefix(f.Path, tb+"tools/") || strings.Contains(f.Path, "modules") || strings.Contains(f.Path, "git") {
			got = append(got, strings.TrimPrefix(f.Path, tb))
		}
	}
	want := []string{"gitx/s7.sh", "node_modulesx/s6.sh", "tools/s1", "tools/s2", "tools/s3", "tools/s4", "tools/s5.sh"}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Errorf("scanned %v, want %v", got, want)
	}
}

func TestBashSizeLimitIsInclusive(t *testing.T) {
	const max = 8 << 20
	pad := func(n int) string { return "#" + strings.Repeat(" ", n-1) }
	root := repo(t, map[string]string{tb + "big.sh": pad(max)})
	if _, err := goimpact.ScanBash(root, func(goimpact.Command) bool { return false }); err != nil {
		t.Errorf("exactly the limit must scan: %v", err)
	}
	write(t, root, map[string]string{tb + "big.sh": pad(max + 1)})
	if _, err := goimpact.ScanBash(root, func(goimpact.Command) bool { return false }); err == nil {
		t.Error("one byte over the limit must be an error")
	}
}

func TestSymlinksAreNotScanned(t *testing.T) {
	root := repo(t, nil)
	if err := os.Symlink(filepath.Join(root, tb, "a.sh"), filepath.Join(root, tb, "link.sh")); err != nil {
		t.Skip(err)
	}
	files, err := goimpact.ScanBash(root, func(goimpact.Command) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range files {
		if strings.HasSuffix(f.Path, "link.sh") {
			t.Errorf("a symlink was scanned: %s", f.Path)
		}
	}
}

func runIn(cwd string, args ...string) result {
	var o, e bytes.Buffer
	rc := goimpact.Run(args, cli.Stdio{Out: &o, Err: &e, Cwd: cwd, Env: func(string) string { return "" }})
	return result{o.String(), e.String(), rc}
}

func TestRepoRootResolution(t *testing.T) {
	root := repo(t, nil)
	f := mod + "internal/alpha/alpha.go"
	if r := runIn(root, f); r.rc != 0 || !strings.Contains(r.out, "SHIM\t"+f) {
		t.Errorf("working directory: %+v", r)
	}
	if r := runIn(filepath.Dir(root), "--repo", filepath.Base(root), f); r.rc != 0 {
		t.Errorf("relative --repo: %+v", r)
	}
	if r := runIn("", f); r.rc != 2 || !strings.Contains(r.err, "no --repo and no working directory") {
		t.Errorf("neither: %+v", r)
	}
	if r := runIn(root, "--wide", "-1", f); r.rc != 2 {
		t.Errorf("wide -1: %+v", r)
	}
	if r := runIn(root, "--wide", "1", f); r.rc != 0 {
		t.Errorf("wide 1: %+v", r)
	}
}
