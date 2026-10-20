package kit

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Ports of cases 10-22 of toolbelt/tests/target-paths.test.sh (target_name_for_retro).

type nameEnv struct {
	t    *testing.T
	root string
	n    int
}

// file writes body to a fresh, uniquely named targets file.
func (e *nameEnv) file(body string) string {
	e.n++
	return write(e.t, filepath.Join(e.root, fmt.Sprintf("T%d.md", e.n)), body)
}

func newNameEnv(t *testing.T) *nameEnv { return &nameEnv{t: t, root: physical(t, t.TempDir())} }

func (e *nameEnv) retro(rel string) string {
	e.t.Helper()
	p := filepath.Join(e.root, rel, "retros", "r.md")
	write(e.t, p, "")
	return p
}

func (e *nameEnv) targets(rows ...string) string {
	e.t.Helper()
	body := "# t\n\n| # | Target | Path |\n|---|---|---|\n" + strings.Join(rows, "\n")
	if len(rows) > 0 {
		body += "\n"
	}
	return e.file(body)
}

func (e *nameEnv) row(n int, name, path string) string {
	return fmt.Sprintf("| %d | %s | `%s` |", n, name, path)
}

func (e *nameEnv) look(targets, retro, rh string) (NameResult, int, error) {
	e.t.Helper()
	r, err := NameForRetro(targets, retro, rhEnv(rh))
	return r, RC(err), err
}

func (e *nameEnv) wantName(targets, retro, want string) {
	e.t.Helper()
	r, rc, err := e.look(targets, retro, e.root)
	if rc != 0 || r.Name != want {
		e.t.Fatalf("rc=%d name=%q err=%v, want %q", rc, r.Name, err, want)
	}
}

func TestNameFlatNestedAndListEdges(t *testing.T) { // 10, 11, 12, 13
	e := newNameEnv(t)
	tg := e.targets(e.row(1, "reg-first", e.root+"/first"), e.row(2, "reg-middle", e.root+"/middle"), e.row(3, "reg-last", e.root+"/last"))
	e.wantName(tg, e.retro("middle"), "reg-middle")
	e.wantName(tg, e.retro("first"), "reg-first") // list edges: first and last rows
	e.wantName(tg, e.retro("last"), "reg-last")
	e.wantName(tg, e.retro("middle/corpus"), "reg-middle")
	e.wantName(tg, e.retro("middle/sub/deeper"), "reg-middle")
	single := e.targets(e.row(1, "only-one", e.root+"/solo"))
	e.wantName(single, e.retro("solo"), "only-one")
}

func TestNameNearestAncestorWinsInBothRowOrders(t *testing.T) { // 14
	e := newNameEnv(t)
	a := e.targets(e.row(1, "outer-t", e.root+"/outer"), e.row(2, "inner-t", e.root+"/outer/inner"))
	b := e.targets(e.row(1, "inner-t", e.root+"/outer/inner"), e.row(2, "outer-t", e.root+"/outer"))
	in, out := e.retro("outer/inner"), e.retro("outer")
	for _, tg := range []string{a, b} {
		e.wantName(tg, in, "inner-t")
		e.wantName(tg, out, "outer-t")
	}
}

func TestNameResearchHomeTokens(t *testing.T) { // 15
	e := newNameEnv(t)
	tg := e.targets(e.row(1, "rh-plain", "$RESEARCH_HOME/rhp"), e.row(2, "rh-braced", "${RESEARCH_HOME}/rhb"))
	e.wantName(tg, e.retro("rhp"), "rh-plain")
	e.wantName(tg, e.retro("rhb/corpus"), "rh-braced")
}

func TestNameFallbacksAndDecoration(t *testing.T) { // 16a, 16b, 16c
	e := newNameEnv(t)
	e.wantName(e.targets(e.row(1, "", e.root+"/blankname")), e.retro("blankname"), "blankname")
	tg := e.targets(e.row(1, "two words", e.root+"/spacename"))
	r, rc, err := e.look(tg, e.retro("spacename"), e.root)
	wantWarn := "WARN: target name cell 'two words' for " + e.root + "/spacename contains whitespace and cannot be a label — using basename"
	if rc != 0 || r.Name != "spacename" || len(r.Warnings) != 1 || r.Warnings[0] != wantWarn {
		t.Fatalf("rc=%d name=%q warnings=%q err=%v", rc, r.Name, r.Warnings, err)
	}
	e.wantName(e.targets(e.row(1, "**bold-name**", e.root+"/boldt")), e.retro("boldt"), "bold-name")
}

func TestNameSymlinksResolvePhysically(t *testing.T) { // 17
	e := newNameEnv(t)
	real := e.retro("real-t")
	if err := os.Symlink(filepath.Join(e.root, "real-t"), filepath.Join(e.root, "link-t")); err != nil {
		t.Fatal(err)
	}
	e.wantName(e.targets(e.row(1, "sym-t", e.root+"/real-t")), filepath.Join(e.root, "link-t/retros/r.md"), "sym-t")
	e.wantName(e.targets(e.row(1, "sym-t", e.root+"/link-t")), real, "sym-t")
}

func TestNameNoMatchIsRC2AndFailuresAreRC1(t *testing.T) { // 18, 19a-f
	e := newNameEnv(t)
	tg := e.targets(e.row(1, "reg", e.root+"/middle"))
	e.retro("middle")
	r, rc, err := e.look(tg, e.retro("stranger"), e.root)
	if rc != 2 || !errors.Is(err, ErrNoAncestor) || r.Name != "" {
		t.Fatalf("no-match: rc=%d err=%v name=%q", rc, err, r.Name)
	}
	emptyT := e.file("")
	cases := []struct {
		label, tg, retro, wantMsg string
	}{
		{"absent targets", filepath.Join(e.root, "nope.md"), e.retro("middle"), "target-paths: cannot read " + filepath.Join(e.root, "nope.md")},
		{"empty targets", emptyT, e.retro("middle"), "no registered target paths parsed from " + emptyT},
		{"header only", e.targets(), e.retro("middle"), "no registered target paths parsed from"},
		{"missing retro dir", tg, filepath.Join(e.root, "no-such-dir/retros/r.md"), "target-paths: retro directory not found for " + filepath.Join(e.root, "no-such-dir/retros/r.md")},
		{"no arguments", "", "", "target-paths: target_name_for_retro needs <targets_md> <retro>"},
	}
	for _, c := range cases {
		_, rc, err := e.look(c.tg, c.retro, e.root)
		if rc != 1 || err == nil || !strings.Contains(err.Error(), c.wantMsg) {
			t.Errorf("%s: rc=%d err=%v want substring %q", c.label, rc, err, c.wantMsg)
		}
	}
	if os.Geteuid() != 0 {
		locked := write(t, filepath.Join(e.root, "locked.md"), "| `/x` |\n")
		_ = os.Chmod(locked, 0)
		if _, rc, err := e.look(locked, e.retro("middle"), e.root); rc != 1 || err == nil || !strings.Contains(err.Error(), "cannot read") {
			t.Errorf("unreadable: rc=%d err=%v", rc, err)
		}
	}
}

func TestNameGhostRowsAreSkipped(t *testing.T) { // 20, 21b
	e := newNameEnv(t)
	e.retro("middle")
	e.wantName(e.targets(e.row(1, "ghost", e.root+"/ghost-dir"), e.row(2, "real-after-ghost", e.root+"/middle")), e.retro("middle"), "real-after-ghost")
	e.wantName(e.targets(e.row(1, "solid", e.root+"/middle"), e.row(2, "ghost-last", e.root+"/ghost-dir-2")), e.retro("middle"), "solid")
}

func TestNameWrongResearchHomeIsAbsentInputNotNoMatch(t *testing.T) { // 21a, 21c, 21d
	e := newNameEnv(t)
	e.retro("rhp")
	rhRows := e.targets(e.row(1, "rh-plain", "$RESEARCH_HOME/rhp"))
	_, rc, err := e.look(rhRows, e.retro("rhp"), "/nonexistent-research-home")
	if rc != 1 || err == nil || !strings.Contains(err.Error(), "no registered target path in") ||
		!strings.Contains(err.Error(), "RESEARCH_HOME (/nonexistent-research-home) is probably wrong") {
		t.Fatalf("21a: rc=%d err=%v", rc, err)
	}
	// 21c: an absolute-only registry of ghosts stays the quiet no-match (RESEARCH_HOME cannot be the cause)
	abs := e.targets(e.row(1, "only-ghost", e.root+"/ghost-dir-3"))
	if _, rc, err := e.look(abs, e.retro("rhp"), e.root); rc != 2 || !errors.Is(err, ErrNoAncestor) {
		t.Fatalf("21c: rc=%d err=%v", rc, err)
	}
	mixed := e.targets(e.row(1, "abs-ghost", e.root+"/ghost-dir-4"), e.row(2, "rh-row", "$RESEARCH_HOME/rhp"))
	if _, rc, _ := e.look(mixed, e.retro("rhp"), "/nonexistent-research-home"); rc != 1 {
		t.Fatalf("21d: rc=%d", rc)
	}
}

func TestNameRowSelectionUsesThePathCellOnly(t *testing.T) { // 22a, 22b, 22c
	e := newNameEnv(t)
	hdr := func(rows ...string) string {
		return e.file("# t\n\n| # | Target | Path | Notes |\n|---|---|---|---|\n" + strings.Join(rows, "\n") + "\n")
	}
	e.wantName(hdr(
		fmt.Sprintf("| 1 | decoy-first | `%s/first` | superseded by `%s/last` |", e.root, e.root),
		fmt.Sprintf("| 2 | the-real-last | `%s/last` | none |", e.root)), e.retro("last"), "the-real-last")
	e.wantName(hdr(
		fmt.Sprintf("| 1 | the-real-first | `%s/first` | none |", e.root),
		fmt.Sprintf("| 2 | decoy-last | `%s/last` | see `%s/first` |", e.root, e.root)), e.retro("first"), "the-real-first")
	e.retro("pfxlong")
	e.wantName(e.targets(e.row(1, "long-one", e.root+"/pfxlong"), e.row(2, "short-one", e.root+"/pfx")), e.retro("pfx"), "short-one")
}
