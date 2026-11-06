package goimpact_test

import (
	"os"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

// declaredBlind reads testdata/go-blindspot.txt: one `<path> <class>` line per Go blind-spot bash file. The
// classifier derives the set; the list is the reviewed record, so a change to it is visible in review.
func declaredBlind(t *testing.T) map[string]string {
	t.Helper()
	b, err := os.ReadFile("testdata/go-blindspot.txt")
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, l := range strings.Split(string(b), "\n") {
		if l = strings.TrimSpace(l); l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		f := strings.Fields(l)
		if len(f) != 2 {
			t.Fatalf("malformed line in go-blindspot.txt: %q", l)
		}
		out[f[0]] = f[1]
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
	derived := map[string]string{}
	for _, f := range files {
		if len(f.Calls) > 0 {
			callers++
		}
		for _, c := range f.Calls {
			forms[c.Form] = true
		}
		if f.Blind() != "" {
			derived[f.Path] = f.Blind()
		}
		if f.Exempt != "" {
			exempt[f.Path] = unresolved(f)
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
	declared := declaredBlind(t)
	for _, p := range sortedKeys(derived) {
		if declared[p] != derived[p] {
			t.Errorf("blind spot %s (%s) is missing from, or differs in, testdata/go-blindspot.txt (listed: %q)", p, derived[p], declared[p])
		}
	}
	for _, p := range sortedKeys(declared) {
		if _, ok := derived[p]; !ok {
			t.Errorf("stale entry in testdata/go-blindspot.txt: %s is no longer a blind spot", p)
		}
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

func unresolved(f goimpact.BashFile) bool {
	for _, m := range f.Mentions {
		if m.Class != goimpact.ClassA && m.Class != goimpact.ClassB && !m.Resolved {
			return true
		}
	}
	return false
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
