package parity

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

type linkSpec struct{ at, target string }

func mkLinks(t *testing.T, root string, links []linkSpec) {
	t.Helper()
	for _, l := range links {
		p := filepath.Join(root, l.at)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(l.target, p); err != nil {
			t.Fatal(err)
		}
	}
}

// scanWithin runs scanSymlinks in a goroutine so a missing hop limit is a named
// failure inside the default test timeout instead of a hang.
func scanWithin(t *testing.T, root string) ([]UnsafeLink, error) {
	t.Helper()
	type out struct {
		links []UnsafeLink
		err   error
	}
	ch := make(chan out, 1)
	go func() {
		l, err := scanSymlinks(root)
		ch <- out{l, err}
	}()
	select {
	case o := <-ch:
		return o.links, o.err
	case <-time.After(5 * time.Second):
		t.Fatalf("scan did not terminate within 5s (hop limit missing?)")
		return nil, nil
	}
}

func scanPaths(t *testing.T, root string) []string {
	t.Helper()
	got, err := scanWithin(t, root)
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, u := range got {
		paths = append(paths, u.Path)
	}
	sort.Strings(paths)
	return paths
}

func TestScanSymlinks(t *testing.T) {
	tests := []struct {
		name  string
		links []linkSpec
		want  []string // relative paths of the links that must be reported
	}{
		{"no links", nil, nil},
		{"absolute outward", []linkSpec{{"l", "/etc/passwd"}}, []string{"l"}},
		{"absolute pointing back inside the root", []linkSpec{{"l", "@ROOT@/f.md"}}, []string{"l"}},
		{"relative climbing out", []linkSpec{{"sub/l", "../../x"}}, []string{"sub/l"}},
		{"relative one up from the top", []linkSpec{{"l", "../x"}}, []string{"l"}},
		{"inward relative", []linkSpec{{"l", "f.md"}}, nil},
		{"inward relative up and down", []linkSpec{{"sub/l", "../f.md"}}, nil},
		{"inward dangling", []linkSpec{{"l", "nothing/here"}}, nil},
		{"inward dir link", []linkSpec{{"dl", "sub"}}, nil},
		{"dot dot that stays inside", []linkSpec{{"sub/deeper/l", "../../f.md"}}, nil},
		{"chain escaping on the second hop", []linkSpec{{"a", "sub/b"}, {"sub/b", "../../out"}}, []string{"a", "sub/b"}},
		{"chain escaping on the third hop", []linkSpec{{"a", "b"}, {"b", "c"}, {"c", "/abs"}}, []string{"a", "b", "c"}},
		{"escape through an intermediate dir link", []linkSpec{{"dl", "sub"}, {"x", "dl/../../out"}}, []string{"x"}},
		{"link through an inward dir link stays inward", []linkSpec{{"dl", "sub"}, {"x", "dl/f.md"}}, nil},
		{"two escaping links", []linkSpec{{"one", "/a"}, {"two/three", "../../b"}}, []string{"one", "two/three"}},
		{"cycle hits the hop limit", []linkSpec{{"a", "b"}, {"b", "a"}}, []string{"a", "b"}},
		{"self link hits the hop limit", []linkSpec{{"a", "a"}}, []string{"a"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			writeTree(t, root, map[string]string{"f.md": "x", "sub/g.md": "y", "sub/deeper/h.md": "z"})
			links := make([]linkSpec, len(tt.links))
			for i, l := range tt.links {
				links[i] = linkSpec{l.at, strings.ReplaceAll(l.target, "@ROOT@", root)}
			}
			mkLinks(t, root, links)
			got := scanPaths(t, root)
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Fatalf("reported %v, want %v", got, tt.want)
			}
		})
	}
}

// TestScanSymlinksHopLimitIsExact pins the boundary: a chain whose head needs
// exactly maxLinkHops traversals is inward, one more is refused (head only).
func TestScanSymlinksHopLimitIsExact(t *testing.T) {
	for n, want := range map[int]string{maxLinkHops + 1: "", maxLinkHops + 2: "l0"} {
		root := t.TempDir()
		writeTree(t, root, map[string]string{"f.md": "x"})
		var links []linkSpec
		for i := 0; i < n; i++ {
			next := fmt.Sprintf("l%d", i+1)
			if i == n-1 {
				next = "f.md"
			}
			links = append(links, linkSpec{fmt.Sprintf("l%d", i), next})
		}
		mkLinks(t, root, links)
		if got := strings.Join(scanPaths(t, root), ","); got != want {
			t.Errorf("chain of %d links: reported %q, want %q", n, got, want)
		}
	}
}

func TestScanSymlinksReportsTargetTextAndReason(t *testing.T) {
	root := t.TempDir()
	mkLinks(t, root, []linkSpec{{"abs", "/etc/hosts"}, {"up", "../x"}, {"loop", "loop"}})
	got, err := scanWithin(t, root)
	if err != nil || len(got) != 3 {
		t.Fatalf("%v %v", got, err)
	}
	by := map[string]UnsafeLink{}
	for _, u := range got {
		by[u.Path] = u
	}
	if by["abs"].Target != "/etc/hosts" || !strings.Contains(by["abs"].Why, "absolute") {
		t.Errorf("abs: %+v", by["abs"])
	}
	if by["up"].Target != "../x" || !strings.Contains(by["up"].Why, "outside") {
		t.Errorf("up: %+v", by["up"])
	}
	if !strings.Contains(by["loop"].Why, "hop") {
		t.Errorf("loop: %+v", by["loop"])
	}
}

func TestScanSymlinksAbsentRootIsAnError(t *testing.T) {
	if _, err := scanSymlinks(filepath.Join(t.TempDir(), "gone")); err == nil {
		t.Fatal("an unreadable root must be an error, not 'no links'")
	}
}

// ran reports whether each fake side executed (it touches a marker outside the sandbox).
func markers(t *testing.T) (dir string, legacy, rsdd string) {
	t.Helper()
	dir = t.TempDir()
	return dir, "touch=" + filepath.Join(dir, "legacy"), "touch=" + filepath.Join(dir, "rsdd")
}

func ranSides(dir string) (legacy, rsdd bool) {
	_, e1 := os.Stat(filepath.Join(dir, "legacy"))
	_, e2 := os.Stat(filepath.Join(dir, "rsdd"))
	return e1 == nil, e2 == nil
}

func TestCorpusWithEscapingLinksIsRefused(t *testing.T) {
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.md"), []byte("orig"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := newRig(t)
	scratch := filepath.Join(r.runner.Cfg.Work, "sandbox", "corpus")
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello", "sub/g.md": "g"})
	links := []linkSpec{
		{"abs-out", filepath.Join(outside, "secret.md")},
		{"abs-in", filepath.Join(scratch, "f.md")},
		{"sub/up", "../../x"},
		{"ok-inward", "f.md"},
		{"ok-dangling", "no/such/thing"},
		{"ok-dir", "sub"},
	}
	mkLinks(t, c1, links)
	before := mustFingerprint(t, c1)
	dir, lm, rm := markers(t)

	r.addCase("c", []string{lm, "catf={{corpus}}/f.md"}, []string{rm, "catf={{corpus}}/f.md"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
	if len(rep.Results) != 1 || rep.Results[0].Status != StatusFailed {
		t.Fatalf("an unsafe link must fail the case: %s %v", rep.Summary(), rep.Results)
	}
	msg := joined(rep.Results[0].Problems)
	if !hasKind(rep.Results[0].Problems, KindUnsafeLink) {
		t.Fatalf("want %s, got:\n%s", KindUnsafeLink, msg)
	}
	for _, want := range []string{
		`abs-out -> "` + filepath.Join(outside, "secret.md") + `"`,
		`abs-in -> "` + filepath.Join(scratch, "f.md") + `"`,
		`sub/up -> "../../x"`,
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal must name %q:\n%s", want, msg)
		}
	}
	for _, ok := range []string{"ok-inward", "ok-dangling", "ok-dir"} {
		if strings.Contains(msg, ok) {
			t.Errorf("inward link %s must not be reported:\n%s", ok, msg)
		}
	}
	if l, rr := ranSides(dir); l || rr {
		t.Fatalf("both sides must be skipped (legacy ran=%v rsdd ran=%v)", l, rr)
	}
	if rep.Counts.Failed != 1 || rep.Counts.Skipped != 0 || rep.Counts.Equal != 0 || !rep.Failed() {
		t.Fatalf("a refusal is a failure in the summary, never a skip or a pass: %s", rep.Summary())
	}
	assertUntouched(t, c1, before)
	if b, _ := os.ReadFile(filepath.Join(outside, "secret.md")); string(b) != "orig" {
		t.Fatalf("outside file touched: %q", b)
	}
}

func TestCorpusWithOnlyInwardLinksRuns(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "hello", "sub/g.md": "g"})
	mkLinks(t, c1, []linkSpec{{"in", "f.md"}, {"sub/back", "../f.md"}, {"dangling", "nope/x"}, {"dirlink", "sub"}})
	dir, lm, rm := markers(t)
	res := runCorpusCase(t, r, c1, []string{lm, "rl={{corpus}}/in", "rl={{corpus}}/dangling"}, []string{rm, "out=f.md\nnope/x\n"}, nil)
	if res.Status == StatusFailed && hasKind(res.Problems, KindUnsafeLink) {
		t.Fatalf("inward links, dangling ones included, are allowed: %s", joined(res.Problems))
	}
	if l, rr := ranSides(dir); !l || !rr {
		t.Fatalf("both sides must run (legacy=%v rsdd=%v)", l, rr)
	}
}

func TestChainEscapingOnSecondHopNamesEveryLink(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "x"})
	mkLinks(t, c1, []linkSpec{{"a", "sub/b"}, {"sub/b", "../../out"}, {"also", "/abs/elsewhere"}})
	res := runCorpusCase(t, r, c1, []string{"exists={{corpus}}/f.md"}, []string{"exists={{corpus}}/f.md"}, nil)
	msg := joined(res.Problems)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindUnsafeLink) {
		t.Fatalf("%s %s", res.Status, msg)
	}
	for _, want := range []string{`a -> "sub/b"`, `sub/b -> "../../out"`, `also -> "/abs/elsewhere"`} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal must name %q:\n%s", want, msg)
		}
	}
}

func TestFixtureInputsGetTheSameRefusal(t *testing.T) {
	r := newRig(t)
	dir, lm, rm := markers(t)
	r.addCase("c", []string{lm, "out=a"}, []string{rm, "out=a"}, false, map[string]string{"inputs/a.txt": "x"})
	in := filepath.Join(r.specs, "c", "inputs")
	mkLinks(t, in, []linkSpec{{"abs", "/etc/hosts"}, {"deep/up", "../../escape"}, {"ok", "a.txt"}})
	res := r.runner.RunCase(r.load()[0], "")
	msg := joined(res.Problems)
	if res.Status != StatusFailed || !hasKind(res.Problems, KindUnsafeLink) {
		t.Fatalf("fixture inputs/ with escaping links must be refused: %s %s", res.Status, msg)
	}
	for _, want := range []string{`abs -> "/etc/hosts"`, `deep/up -> "../../escape"`} {
		if !strings.Contains(msg, want) {
			t.Errorf("refusal must name %q:\n%s", want, msg)
		}
	}
	if strings.Contains(msg, "ok ->") {
		t.Errorf("inward link reported:\n%s", msg)
	}
	if !strings.Contains(msg, "input") {
		t.Errorf("refusal should say which tree (input):\n%s", msg)
	}
	if l, rr := ranSides(dir); l || rr {
		t.Fatalf("both sides must be skipped (legacy=%v rsdd=%v)", l, rr)
	}

	// An inward-only fixture runs.
	r2 := newRig(t)
	r2.addCase("c", []string{"out=a"}, []string{"out=a"}, false, map[string]string{"inputs/a.txt": "x"})
	mkLinks(t, filepath.Join(r2.specs, "c", "inputs"), []linkSpec{{"ok", "a.txt"}, {"dangling", "no/where"}})
	if res := r2.runner.RunCase(r2.load()[0], ""); res.Status != StatusEqual {
		t.Fatalf("inward links in inputs/ are allowed: %s %s", res.Status, joined(res.Problems))
	}
}

func TestRefusalAppliesToRunAllSummary(t *testing.T) {
	r := newRig(t)
	c1 := mkCorpus(t, "one", map[string]string{"f.md": "x"})
	mkLinks(t, c1, []linkSpec{{"l", "/etc/hosts"}})
	r.addCase("a-plain", []string{"out=a"}, []string{"out=a"}, false, map[string]string{})
	r.addCase("b-corpus", []string{"catf={{corpus}}/f.md"}, []string{"catf={{corpus}}/f.md"}, true, map[string]string{})
	rep := r.runner.RunAll(r.load(), Options{CorpusMode: true, Corpora: []string{c1}})
	want := "parity: compared=2 equal=1 declared-divergent=0 failed=1 absent-corpora=0 skipped=0"
	if rep.Summary() != want {
		t.Fatalf("got %q want %q", rep.Summary(), want)
	}
}
