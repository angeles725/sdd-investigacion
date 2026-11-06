package goimpact_test

import (
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

// declaredUnclassifiable reads testdata/unclassifiable.txt: the exact set of bash files allowed to exec rsdd in a
// form the enumerator cannot resolve, or to name RSDD_BIN outside a call (C9 blind spots). A file here makes
// every change that reaches a command FULL, so the list is data, reviewed on every change to it.
func declaredUnclassifiable(t *testing.T) []string {
	t.Helper()
	b, err := os.ReadFile("testdata/unclassifiable.txt")
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.HasPrefix(l, "#") {
			out = append(out, l)
		}
	}
	return out
}

// C1 for bash: every bash file that execs rsdd maps to a recovered command, or is on the declared list.
func TestBashEnumeratorMatchesRegistryOnTheRealTree(t *testing.T) {
	repo := realRepo(t)
	m, err := goimpact.Load(repo)
	if err != nil {
		t.Fatal(err)
	}
	known := map[goimpact.Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	files, err := goimpact.ScanBash(repo, func(c goimpact.Command) bool { return known[c] })
	if err != nil {
		t.Fatal(err)
	}
	callers, forms, exempt := 0, map[string]bool{}, map[string]bool{}
	var unclass []string
	for _, f := range files {
		if len(f.Calls) > 0 {
			callers++
		}
		for _, c := range f.Calls {
			forms[c.Form] = true
		}
		if len(f.Unclass) > 0 && f.Exempt == "" {
			unclass = append(unclass, f.Path)
		}
		if f.Exempt != "" {
			exempt[f.Path] = len(f.Unclass) > 0
		}
	}
	if callers < 40 {
		t.Errorf("only %d bash files resolve to a command; the enumerator is blind to a form (forms seen: %v)", callers, keys(forms))
	}
	// the literal `rsdd <group> <name>` form is recognised (synthetic tests) but no real script uses it today
	for _, f := range []string{"rsdd_exec", "rsdd_exec_hook", "$RSDD_BIN"} {
		if !forms[f] {
			t.Errorf("form %q never matched on the real tree (seen %v)", f, keys(forms))
		}
	}
	sort.Strings(unclass)
	if strings.Join(unclass, "\n") != strings.Join(declaredUnclassifiable(t), "\n") {
		t.Errorf("unclassifiable bash files differ from the declared list:\n got  %v\n want %v", unclass, declaredUnclassifiable(t))
	}
	// a stale exemption: the file lost its unresolved form, or is gone from the scan
	for p := range goimpact.Exemptions() {
		if _, seen := exempt[p]; !seen {
			t.Errorf("exemption for %s names a file the scan did not find", p)
		}
	}
	for p, still := range exempt {
		if !still {
			t.Errorf("exemption for %s is stale: the file has no unresolved rsdd form any more", p)
		}
	}
	// every command that has a stable shim has at least one caller
	called := map[goimpact.Command]bool{}
	for _, f := range files {
		for _, c := range f.Calls {
			called[c.Cmd] = true
		}
	}
	if !called[goimpact.Command{Group: "retro", Name: "stage-issues"}] {
		t.Errorf("retro stage-issues has no recovered bash caller")
	}
}
