package issuesdue

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Probe tests: every case builds a kit (research-sdd/TARGETS.md registering one target), a retro and a cache file in
// a temp dir, and asks for the verdict `rsdd retro reconcile --issues-cache F <retro>` gives. The equivalence with the
// command itself, over its whole case table, is pinned by internal/retro/reconcile (TestProbeAgreesWithTheCommand).

const (
	tHead    = "## Proposed kit deltas\n\n| # | Change |\n|---|---|\n"
	tPending = "<!-- review-status: pending -->\n# retro\n\n"
)

func tRows(ids ...string) string {
	var b strings.Builder
	for _, id := range ids {
		b.WriteString("| " + id + " | change |\n")
	}
	return b.String()
}

func tSigs(prefix string, ids ...string) string {
	var b strings.Builder
	for _, id := range ids {
		b.WriteString("Source retro: " + prefix + " · " + id + "\n")
	}
	return b.String()
}

type tBox struct {
	root, kit, retro, cache string
	env                     map[string]string
}

// newBox lays out <root>/kit/research-sdd/TARGETS.md registering <root>/rh/tgt, the retro at <retroRel> under
// <root>/rh/tgt and the cache file with the given bodies.
func newBox(t *testing.T, retroRel, retro, cache string) *tBox {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	b := &tBox{root: root, kit: filepath.Join(root, "kit"), cache: filepath.Join(root, "cache.txt"), env: map[string]string{"HOME": root}}
	mustMkdir(t, filepath.Join(b.kit, "research-sdd", "toolbelt"))
	mustWrite(t, filepath.Join(b.kit, "research-sdd", "TARGETS.md"), "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | tgt | `"+filepath.Join(root, "rh", "tgt")+"` |\n")
	b.retro = filepath.Join(root, "rh", "tgt", retroRel)
	mustMkdir(t, filepath.Dir(b.retro))
	mustWrite(t, b.retro, retro)
	mustWrite(t, b.cache, cache)
	return b
}

func (b *tBox) query() Query {
	return Query{Retro: b.retro, Cache: b.cache, Toolbelt: filepath.Join(b.kit, "research-sdd", "toolbelt"), Cwd: b.root,
		Env: func(k string) string { return b.env[k] }}
}

func TestProbeUntrackedRowsInRowOrder(t *testing.T) {
	for _, c := range []struct {
		name, retro, cache string
		want               []string
	}{
		{"every open row has an issue", tPending + tHead + tRows("D1", "D2"), tSigs("tgt/retros/r.md", "D1", "D2"), nil},
		{"one row without an issue", tPending + tHead + tRows("D1", "D2", "D3"), tSigs("tgt/retros/r.md", "D1", "D3"), []string{"D2"}},
		{"row order, not issue order", tPending + tHead + tRows("D3", "D1", "D2"), tSigs("tgt/retros/r.md", "D2"), []string{"D3", "D1"}},
		{"an empty cache tracks nothing", tPending + tHead + tRows("D1", "D2"), "", []string{"D1", "D2"}},
		{"an issue of another retro tracks nothing", tPending + tHead + tRows("D1"), tSigs("tgt/retros/other.md", "D1"), []string{"D1"}},
		{"an issue of another target tracks nothing", tPending + tHead + tRows("D1"), tSigs("zzz/retros/r.md", "D1"), []string{"D1"}},
		{"an orphaned issue is not an untracked row", tPending + tHead + tRows("D1"), tSigs("tgt/retros/r.md", "D1", "D9"), nil},
		{"an applied retro has no open row", "<!-- review-status: applied 2026-01-01 -->\n# r\n\n" + tHead + tRows("D1"), "", nil},
		{"a dismissed retro has no open row", "<!-- review-status: dismissed -->\n# r\n\n" + tHead + tRows("D1"), "", nil},
		{"a partial marker leaves the unshipped rows open", "<!-- review-status: applied PARTIAL shipped: D1 -->\n# r\n\n" + tHead + tRows("D1", "D2"), "", []string{"D2"}},
		{"a row id with a pipe or an unsafe character is never open", tPending + tHead + tRows("D1", "D 2", "D@3"), "", []string{"D1"}},
		{"a retro without a delta section", "# r\n\nnothing\n", "", nil},
		{"a NUL byte in the cache is dropped", tPending + tHead + tRows("D1"), "Source retro: tgt/retros/r.md · D\x001\n", nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := newBox(t, "retros/r.md", c.retro, c.cache)
			got := Probe(b.query())
			if got.Failure != "" || got.OutOfScope != "" || !reflect.DeepEqual(got.Untracked, c.want) {
				t.Errorf("Probe = %+v, want untracked %v and no stop", got, c.want)
			}
		})
	}
}

// An issue written before #1286 carries the directory name of the retro, not the registered target name.
func TestProbeLegacySignaturePrefixTracksTheRow(t *testing.T) {
	b := newBox(t, "sub/retros/r.md", tPending+tHead+tRows("D1", "D2"), tSigs("sub/retros/r.md", "D1"))
	if got := Probe(b.query()); !reflect.DeepEqual(got.Untracked, []string{"D2"}) || got.Failure != "" {
		t.Errorf("Probe = %+v, want D2 untracked (D1 is tracked by the legacy prefix)", got)
	}
}

func TestProbeStopsAreFailuresNeverAZero(t *testing.T) {
	good := tPending + tHead + tRows("D1")
	for _, c := range []struct {
		name string
		mod  func(b *tBox, q *Query)
		want string // with @ROOT@ for the box root
	}{
		{"an unreadable cache", func(b *tBox, q *Query) { q.Cache = filepath.Join(b.root, "no-cache.txt") },
			"degraded: --issues-cache file not readable: @ROOT@/no-cache.txt"},
		{"an invalid list limit", func(b *tBox, q *Query) { b.env["RECONCILE_ISSUES_LIST_LIMIT"] = "0" },
			"degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '0')"},
		{"an absent retro", func(b *tBox, q *Query) { q.Retro = filepath.Join(b.root, "rh", "tgt", "retros", "gone.md") },
			"absent-input: retro not found: @ROOT@/rh/tgt/retros/gone.md"},
		{"no kit", func(b *tBox, q *Query) { q.Toolbelt = "" },
			"reconcile-issues: cannot find the kit toolbelt: "},
		{"an unreadable retro", func(b *tBox, q *Query) { must(t, os.Chmod(b.retro, 0)) },
			"degraded: retro not readable: @ROOT@/rh/tgt/retros/r.md — cannot audit, no verdict"},
		{"a shipped range too large to expand", func(b *tBox, q *Query) {
			mustWrite(t, b.retro, "<!-- review-status: applied PARTIAL shipped: D1-D99999999 -->\n# r\n\n"+tHead+tRows("D1"))
		}, "degraded: the review-status marker of r.md lists a shipped: range too large to expand ("},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := newBox(t, "retros/r.md", good, tSigs("tgt/retros/r.md", "D1"))
			q := b.query()
			c.mod(b, &q)
			if c.name == "an unreadable retro" && os.Geteuid() == 0 {
				t.Skip("root reads a mode-000 file")
			}
			got := Probe(q)
			want := strings.ReplaceAll(c.want, "@ROOT@", b.root)
			if !strings.HasPrefix(got.Failure, want) || got.OutOfScope != "" || len(got.Untracked) != 0 {
				t.Errorf("Probe = %+v, want the failure %q", got, want)
			}
		})
	}
}

// A failure carries every stderr line of the command before the stop, in order: the target warning comes first.
func TestProbeFailureKeepsTheNotesBeforeTheStop(t *testing.T) {
	b := newBox(t, "retros/r.md", tPending+tHead+tRows("D1"), "")
	q := b.query()
	q.Cache = filepath.Join(b.root, "missing")
	mustWrite(t, filepath.Join(b.kit, "research-sdd", "TARGETS.md"), "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | other | `"+filepath.Join(b.root, "other")+"` |\n")
	want := "WARN: target directory '" + filepath.Join(b.root, "rh", "tgt") + "' not found in " + filepath.Join(b.kit, "research-sdd", "TARGETS.md") +
		" — using basename 'tgt'\ndegraded: --issues-cache file not readable: " + q.Cache
	if got := Probe(q); got.Failure != want {
		t.Errorf("Failure = %q, want %q", got.Failure, want)
	}
}

func TestProbeStructuralDirectoryIsRefused(t *testing.T) {
	b := newBox(t, "retros/r.md", tPending+tHead+tRows("D1"), "")
	mustWrite(t, filepath.Join(b.kit, "research-sdd", "TARGETS.md"), "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | other | `"+filepath.Join(b.root, "other")+"` |\n")
	other := filepath.Join(b.root, "corpus", "retros", "r.md")
	mustMkdir(t, filepath.Dir(other))
	mustWrite(t, other, tPending+tHead+tRows("D1"))
	q := b.query()
	q.Retro = other
	got := Probe(q)
	want := "reconcile-issues: cannot resolve target for '" + other + "' — no ancestor directory is registered in " +
		filepath.Join(b.kit, "research-sdd", "TARGETS.md") + " (basename 'corpus' is a structural directory, not a target)"
	if got.Failure != want {
		t.Errorf("Failure = %q, want %q", got.Failure, want)
	}
}

func TestProbeMarkerOutOfScopeClassifiesNothing(t *testing.T) {
	b := newBox(t, "retros/r.md", "# r\n\ntext\n<!-- review-status: applied -->\n\n"+tHead+tRows("D1"), "")
	got := Probe(b.query())
	want := "out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in r.md — refusing to classify (kit issue #1099); move the marker into the leading block"
	if got.OutOfScope != want || got.Failure != "" || len(got.Untracked) != 0 {
		t.Errorf("Probe = %+v, want only the out-of-scope line", got)
	}
}

func TestProbeResolvesARelativeRetroAgainstCwdAndTheKitFromTheEnvironment(t *testing.T) {
	b := newBox(t, "retros/r.md", tPending+tHead+tRows("D1", "D2"), tSigs("tgt/retros/r.md", "D1"))
	q := b.query()
	q.Retro, q.Cwd, q.Toolbelt = "r.md", filepath.Dir(b.retro), ""
	mustWrite(t, filepath.Join(b.kit, "research-sdd", "toolbelt", "reconcile-issues.sh"), "#!/bin/sh\n")
	b.env["RESEARCH_SDD_KIT"] = filepath.Join(b.kit, "research-sdd")
	if got := Probe(q); !reflect.DeepEqual(got.Untracked, []string{"D2"}) || got.Failure != "" {
		t.Errorf("Probe = %+v, want D2 untracked", got)
	}
}

// A TARGETS.md that cannot be read as a registry is an operational failure, never the basename fallback: the reader's
// own line comes first, then the stop.
func TestProbeUnreadableRegistryIsAnOperationalFailure(t *testing.T) {
	for name, targets := range map[string]string{"no rows": "# t\n\nno table here\n", "an empty table": "# t\n\n| # | Target | Path |\n|---|---|---|\n"} {
		t.Run(name, func(t *testing.T) {
			b := newBox(t, "retros/r.md", tPending+tHead+tRows("D1"), "")
			md := filepath.Join(b.kit, "research-sdd", "TARGETS.md")
			mustWrite(t, md, targets)
			want := "target-paths: no registered target paths parsed from " + md + "\n" +
				"reconcile-issues: cannot resolve target for '" + b.retro + "' — operational failure reading " + md + " (see message above)"
			if got := Probe(b.query()); got.Failure != want || len(got.Untracked) != 0 {
				t.Errorf("Probe = %+v, want the failure %q", got, want)
			}
		})
	}
}
