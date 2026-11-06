package goimpact_test

import (
	"fmt"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

const tb = "research-sdd/toolbelt/"

func scanAll(t *testing.T, extra map[string]string) []goimpact.BashFile {
	t.Helper()
	root := repo(t, extra)
	m, err := goimpact.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	known := map[goimpact.Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	files, err := goimpact.ScanBash(root, func(c goimpact.Command) bool { return known[c] })
	if err != nil {
		t.Fatal(err)
	}
	return files
}

func scan(t *testing.T, extra map[string]string) map[string]goimpact.BashFile {
	t.Helper()
	out := map[string]goimpact.BashFile{}
	for _, f := range scanAll(t, extra) {
		out[strings.TrimPrefix(f.Path, tb)] = f
	}
	return out
}

// shape renders the mentions as "C+ D- A" (+ resolved, - unresolved).
func shape(f goimpact.BashFile) string {
	var p []string
	for _, m := range f.Mentions {
		s := m.Class
		if m.Class == goimpact.ClassC || m.Class == goimpact.ClassD {
			s += map[bool]string{true: "+", false: "-"}[m.Resolved]
		}
		p = append(p, s)
	}
	return strings.Join(p, " ")
}

func TestEveryRecognisedFormResolves(t *testing.T) {
	got := scan(t, nil)
	want := map[string]string{
		"a.sh": "rsdd_exec|g one", "b1.sh": "rsdd_exec_hook|b first", "b2.sh": "$RSDD_BIN|b mid",
		"tests/x.test.sh": "$RSDD_BIN|g one",
	}
	for f, w := range want {
		c := got[f].Calls
		if len(c) != 1 || c[0].Form+"|"+c[0].Cmd.String() != w || got[f].Blind() != "" {
			t.Errorf("%s: %+v", f, got[f])
		}
	}
	b3 := got["b3.sh"].Calls
	if len(b3) != 2 || b3[0].Form != "$RSDD_REAL_BIN" || b3[0].Cmd.String() != "b last" || b3[1].Form != "rsdd" || b3[1].Cmd.String() != "version" {
		t.Errorf("b3.sh: %+v", got["b3.sh"])
	}
}

// One case per class of rule i'. want is the mention shape, blind the file's blind class.
func TestEveryMentionClass(t *testing.T) {
	cases := []struct{ name, src, want, blind string }{
		{"A env prefix", "RSDD_BIN=x bash shim.sh\n", "A", "empty-reach"},
		{"A export", "export RSDD_BIN\n", "A", "empty-reach"},
		{"A declare", "declare -x RSDD_REAL_BIN=1\n", "A", "empty-reach"},
		{"A local", "f() { local RSDD_BIN=1; }\n", "A", "empty-reach"},
		{"A unset", "unset RSDD_BIN\n", "A", "empty-reach"},
		{"A shim named", "RSDD_BIN=x bash \"$T/a.sh\"\n", "A", ""},
		{"B single bracket", "[ -x \"$RSDD_BIN\" ] || exit 2\n", "B", "empty-reach"},
		{"B double bracket across &&", "[[ -n x && -x \"$RSDD_BIN\" ]] && :\n", "B", "empty-reach"},
		{"B test", "test -x \"$RSDD_BIN\"\n", "B", "empty-reach"},
		{"C literal", "\"$RSDD_BIN\" g one\n", "C+", ""},
		{"C non-literal", "\"$RSDD_BIN\" \"$a\" \"$b\"\n", "C-", "C"},
		{"C in $( )", "out=$(\"$RSDD_BIN\" g one)\n", "C+", ""},
		{"C after pipe and &&", "echo x | \"$RSDD_BIN\" g one && \"$RSDD_BIN\" b mid\n", "C+ C+", ""},
		{"C in if", "if ! \"${RSDD_BIN}\" b last; then :; fi\n", "C+", ""},
		{"D literal timeout", "timeout 60 \"$RSDD_BIN\" g one\n", "D+", ""},
		{"D literal run helper", "run_cap \"$RSDD_BIN\" b mid\n", "D+", ""},
		{"D literal env -i", "env -i X=1 \"$RSDD_BIN\" g one\n", "D+", ""},
		{"D non-literal", "printf '%s' \"$RSDD_BIN\"\n", "D-", "D"},
		{"unplaceable eval", "eval \"$RSDD_BIN g one\"\n", "unplaceable", "unplaceable"},
		{"unplaceable bash -c", "bash -c \"$RSDD_BIN g one\"\n", "unplaceable", "unplaceable"},
		{"unplaceable executed here-doc", "bash <<EOF\n$RSDD_BIN g one\nEOF\n", "unplaceable", "unplaceable"},
		{"data here-doc is scanned as code", "cat >s <<'EOF'\n\"$RSDD_BIN\" g one\nEOF\n", "C+", ""},
		{"comment excluded", "# \"$RSDD_BIN\" g one\n", "", ""},
		{"similar name excluded", "RSDD_BINWALK=1 x\n", "", ""},
	}
	files := map[string]string{}
	for i, c := range cases {
		files[fmt.Sprintf("%s%02d.sh", tb, i)] = c.src
	}
	got := scan(t, files)
	for i, c := range cases {
		f := got[fmt.Sprintf("%02d.sh", i)]
		if shape(f) != c.want || f.Blind() != c.blind {
			t.Errorf("%s: shape %q blind %q, want %q %q", c.name, shape(f), f.Blind(), c.want, c.blind)
		}
	}
}

func TestFirstMiddleAndLastMentionAreAllClassified(t *testing.T) {
	got := scan(t, map[string]string{
		tb + "first.sh":  "echo \"$RSDD_BIN\"\n\"$RSDD_BIN\" g one\nexport RSDD_BIN\n",
		tb + "middle.sh": "\"$RSDD_BIN\" g one\necho \"$RSDD_BIN\"\nexport RSDD_BIN\n",
		tb + "last.sh":   "export RSDD_BIN\n\"$RSDD_BIN\" g one\necho \"$RSDD_BIN\"\n",
		tb + "only.sh":   "echo \"$RSDD_BIN\"\n",
	})
	for f, want := range map[string]string{"first.sh": "D- C+ A", "middle.sh": "C+ D- A", "last.sh": "A C+ D-", "only.sh": "D-"} {
		if shape(got[f]) != want || got[f].Blind() != "D" {
			t.Errorf("%s: %q blind %q", f, shape(got[f]), got[f].Blind())
		}
	}
}

func TestUnresolvableRsddExecFormsAreBlindC(t *testing.T) {
	got := scan(t, map[string]string{tb + "v.sh": "rsdd_exec nope nothing\nrsdd_exec_hook sweep\nrsdd_exec g one\nrsdd_exec() { return 2; }\n"})
	if f := got["v.sh"]; shape(f) != "C- C- C+" || f.Blind() != "C" || len(f.Calls) != 1 {
		t.Errorf("%q %q", shape(got["v.sh"]), got["v.sh"].Blind())
	}
}

func TestContinuationLinesAndPrefixWordsAreCommandPosition(t *testing.T) {
	got := scan(t, map[string]string{tb + "p.sh": "if ! X=1 rsdd_exec g \\\n  one; then :; fi\nout=$(\"$RSDD_BIN\" b last)\n"})
	if f := got["p.sh"]; len(f.Calls) != 2 || f.Blind() != "" {
		t.Errorf("%+v", f)
	}
}

func TestRsddModuleScriptsAreNotScanned(t *testing.T) {
	got := scan(t, map[string]string{mod + "internal/x/testdata/fix.sh": "rsdd_exec g one\n"})
	for p := range got {
		if strings.Contains(p, "internal/x") {
			t.Errorf("fixture under the module was scanned: %s", p)
		}
	}
}

// A file that only exports the binary for shims it runs keeps its mapping; one naming no shim is empty-reach.
func TestEmptyReachNeedsNoCallAndNoNamedShim(t *testing.T) {
	got := scan(t, map[string]string{
		tb + "e1.sh": "export RSDD_BIN=/x\n./run-it.sh\n",
		tb + "e2.sh": "export RSDD_BIN=/x\nbash toolbelt/b1.sh --go\n",
		tb + "e3.sh": "export RSDD_BIN=/x\nbash notb1.sh\n",
	})
	for f, want := range map[string]string{"e1.sh": "empty-reach", "e2.sh": "", "e3.sh": "empty-reach"} {
		if got[f].Blind() != want {
			t.Errorf("%s: blind %q, want %q", f, got[f].Blind(), want)
		}
	}
}

// §7: a measured zero differs from a scan that saw nothing. Known count per class on a synthetic tree.
func TestCountClassesOnAKnownTree(t *testing.T) {
	files := scanAll(t, map[string]string{
		tb + "ca.sh": "export RSDD_BIN\n",
		tb + "cb.sh": "[ -x \"$RSDD_BIN\" ]\n",
		tb + "cc.sh": "\"$RSDD_BIN\" \"$x\"\n",
		tb + "cd.sh": "echo \"$RSDD_BIN\"\n",
		tb + "cu.sh": "eval \"$RSDD_BIN\"\n",
	})
	// the six C+ calls of the base tree, one C-; A and B files are empty-reach, so five blind files
	want := "CLASSES\tA=1\tB=1\tC=7\tD=1\tunplaceable=1\tempty-reach=2\tblindspot-files=5"
	if got := goimpact.CountClasses(files).Line(); got != want {
		t.Errorf("got  %s\nwant %s", got, want)
	}
	if got := goimpact.CountClasses(nil).Line(); got != "CLASSES\tA=0\tB=0\tC=0\tD=0\tunplaceable=0\tempty-reach=0\tblindspot-files=0" {
		t.Errorf("empty scan: %s", got)
	}
}
