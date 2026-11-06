package goimpact_test

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

func scan(t *testing.T, extra map[string]string) map[string]goimpact.BashFile {
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
	out := map[string]goimpact.BashFile{}
	for _, f := range files {
		out[strings.TrimPrefix(f.Path, "research-sdd/toolbelt/")] = f
	}
	return out
}

func TestEveryRecognisedFormResolves(t *testing.T) {
	got := scan(t, nil)
	want := map[string]string{
		"a.sh": "rsdd_exec|g one", "b1.sh": "rsdd_exec_hook|b first", "b2.sh": "$RSDD_BIN|b mid",
		"tests/x.test.sh": "$RSDD_BIN|g one",
	}
	for f, w := range want {
		c := got[f].Calls
		if len(c) != 1 || c[0].Form+"|"+c[0].Cmd.String() != w || len(got[f].Unclass) != 0 {
			t.Errorf("%s: %+v", f, got[f])
		}
	}
	// two calls in one file: the REAL_BIN form and the ungrouped literal `rsdd version`
	b3 := got["b3.sh"].Calls
	if len(b3) != 2 || b3[0].Form != "$RSDD_REAL_BIN" || b3[0].Cmd.String() != "b last" || b3[1].Form != "rsdd" || b3[1].Cmd.String() != "version" {
		t.Errorf("b3.sh: %+v", got["b3.sh"])
	}
}

func TestNonCallMentionsAreIgnored(t *testing.T) {
	got := scan(t, map[string]string{"research-sdd/toolbelt/n.sh": "# rsdd_exec g one; $RSDD_BIN x y\necho \"run rsdd verify now\"\nrsdd_exec() { return 2; }\ncd \"$T/../rsdd\"\nRSDD_BINWALK=1\n"})
	if f := got["n.sh"]; len(f.Calls) != 0 || len(f.Unclass) != 0 {
		t.Errorf("%+v", f)
	}
}

// C9: naming RSDD_BIN in code without a resolved call is a blind spot, unless the file resolves a call.
func TestNamingTheBinaryOutsideACallIsABlindSpot(t *testing.T) {
	got := scan(t, map[string]string{
		"research-sdd/toolbelt/bs1.sh": "RSDD_BIN=\"$stub\" bash \"$SHIM\"\n",
		"research-sdd/toolbelt/bs2.sh": "[ -x \"${RSDD_REAL_BIN:-}\" ] || exit 2\n",
		"research-sdd/toolbelt/ok.sh":  "RSDD_BIN=\"$stub\" bash \"$SHIM\"\n\"$RSDD_BIN\" g one\n",
	})
	for _, f := range []string{"bs1.sh", "bs2.sh"} {
		if u := got[f].Unclass; len(u) != 1 || u[0] != "names RSDD_BIN outside a recognised call form" {
			t.Errorf("%s: %+v", f, got[f])
		}
	}
	if f := got["ok.sh"]; len(f.Calls) != 1 || len(f.Unclass) != 0 {
		t.Errorf("a file with a resolved call is not a blind spot: %+v", f)
	}
}

func TestUnresolvableFormsAreUnclassifiable(t *testing.T) {
	got := scan(t, map[string]string{"research-sdd/toolbelt/v.sh": "\"$RSDD_BIN\" \"$grp\" \"$cmd\"\nrsdd_exec nope nothing\nrsdd_exec_hook sweep\nrsdd_exec g one\n"})
	f := got["v.sh"]
	if len(f.Unclass) != 3 || len(f.Calls) != 1 {
		t.Errorf("%+v", f)
	}
}

func TestContinuationLinesAndPrefixWordsAreCommandPosition(t *testing.T) {
	got := scan(t, map[string]string{"research-sdd/toolbelt/p.sh": "if ! X=1 rsdd_exec g \\\n  one; then :; fi\nout=$(\"$RSDD_BIN\" b last)\n"})
	if f := got["p.sh"]; len(f.Calls) != 2 || len(f.Unclass) != 0 {
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
