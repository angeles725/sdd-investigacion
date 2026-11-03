package reconcile

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Boundary and fold tests that need no legacy script (no build tag): they pin comparisons the golden replay
// cannot see, so a mutant of one of them fails here by name under gremlins' -tags nodiff builds.

func TestNameFailureNote(t *testing.T) {
	if msg, ok := nameFailureNote(errors.New("operational")); !ok || msg != "operational" {
		t.Errorf("an operational failure (rc 1) is noted with its message: %q %v", msg, ok)
	}
	if msg, ok := nameFailureNote(nil); ok || msg != "" {
		t.Errorf("a clean run says nothing: %q %v", msg, ok)
	}
	if msg, ok := nameFailureNote(kit.ErrNoAncestor); ok || msg != "" {
		t.Errorf("no registered ancestor (rc 2) says nothing: %q %v", msg, ok)
	}
	if msg, ok := nameFailureNote(kit.ErrStateUsage); ok || msg != "" {
		t.Errorf("a usage error (rc 3) says nothing: %q %v", msg, ok)
	}
}

func runAllReport(t *testing.T, c dcase) Report {
	t.Helper()
	c.all, c.noRetro, c.targets = true, true, targets2
	b := mkBox(t, c)
	rep, err := Run(context.Background(), Options{All: true, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd, Env: noEnv})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return rep
}

// The first retro's typed state wins when several retros of a fleet carry one (rsdd status show reads it).
func TestFleetKeepsTheFirstDegradedAndMarker(t *testing.T) {
	marker := "# retro\n\n## Notes\n\n<!-- review-status: applied -->\n\n" + tableHead + rowsOf("1")
	oos := runAllReport(t, dcase{files: map[string]string{"rh/alpha-target/retros/a.md": marker, "rh/beta-target/retros/b.md": marker}})
	if !strings.Contains(oos.OutOfScopeMarker, "a.md") || strings.Contains(oos.OutOfScopeMarker, "b.md") {
		t.Errorf("OutOfScopeMarker must be the first retro's: %q", oos.OutOfScopeMarker)
	}
	if oos.Fleet == nil || oos.Fleet.OutOfScope != 2 {
		t.Errorf("both markers are counted: %+v", oos.Fleet)
	}

	one := pending + tableHead + rowsOf("1")
	deg := runAllReport(t, dcase{cacheMissing: true, files: map[string]string{"rh/alpha-target/retros/a.md": one, "rh/beta-target/retros/b.md": one}})
	if deg.Degraded == "" || deg.Fleet == nil || deg.Fleet.Degraded != 2 {
		t.Fatalf("both retros degrade: %q %+v", deg.Degraded, deg.Fleet)
	}
	if strings.Contains(deg.Degraded, "b.md") && !strings.Contains(deg.Degraded, "a.md") {
		t.Errorf("Degraded must be the first retro's: %q", deg.Degraded)
	}
}

func TestNewGHClientRepo(t *testing.T) {
	if g := newGHClient(context.Background(), Options{}, "1000", 1000); g.repo != DefaultRepo {
		t.Errorf("an empty Repo reads %q, got %q", DefaultRepo, g.repo)
	}
	if g := newGHClient(context.Background(), Options{Repo: "o/other"}, "1000", 1000); g.repo != "o/other" {
		t.Errorf("Options.Repo must be kept, got %q", g.repo)
	}
}

// RC is gh's own exit code; a call that did not end OK never reads 0 (an output-capped one has no exit code of its own).
func TestRunKeepsRCAndFlagsTheOutputCap(t *testing.T) {
	g, _, _ := newTestClient(t, map[string]string{"open.json": openJSON("a body long enough to pass the cap"), "list-closed.rc": "3"}, nil)
	run := func(args ...string) gh.RunResult {
		t.Helper()
		res, good := g.run(args...)
		if !good {
			t.Fatalf("run %v failed: %v", args, g.err)
		}
		return res
	}
	if res := run("issue", "list", "--state", "open", "--jq", "."); res.State != gh.StateOK || res.RC != 0 {
		t.Errorf("a clean call keeps RC 0: %+v", res)
	}
	if res := run("issue", "list", "--state", "closed"); res.State == gh.StateOK || res.RC != 3 {
		t.Errorf("a failing call keeps its own exit code: %+v", res)
	}
	g.o.MaxBytes = 8
	if res := run("issue", "list", "--state", "open", "--jq", "."); res.State != gh.StateOutputCap || res.RC == 0 {
		t.Errorf("a capped call is never RC 0: %+v", res)
	}
}

// A listing without a line (the REST answer was empty) must not break the scan, and a stale listing is reloaded once.
func TestStateReasonOfEmptyAndStaleListings(t *testing.T) {
	g, b, _ := newTestClient(t, nil, nil)
	if sr, found, ok := g.stateReasonOf(&Report{}, "5"); found || !ok || sr != "" {
		t.Errorf("an empty listing finds nothing: %q %v %v", sr, found, ok)
	}
	if calls := ghCalls(t, b); len(calls) != 2 {
		t.Errorf("the empty listing is loaded once and reloaded once: %v", calls)
	}

	g2, b2, _ := newTestClient(t, map[string]string{"api.json": apiJSON([2]string{"5", "completed"})}, nil)
	g2.sr = stateReasons{loaded: true, repo: "o/r", since: "none", lines: []string{"7 not_planned"}}
	if sr, found, ok := g2.stateReasonOf(&Report{}, "5"); sr != "completed" || !found || !ok {
		t.Errorf("an issue missing from a stale cache is found after the forced reload: %q %v %v", sr, found, ok)
	}
	if calls := ghCalls(t, b2); len(calls) != 1 || !strings.HasPrefix(calls[0], "gh api ") {
		t.Errorf("exactly one reload: %v", calls)
	}
}

// A forced reload of a bounded cache keeps the OLDER bound; an unbounded request stays unbounded.
func TestForcedReloadKeepsTheOlderBound(t *testing.T) {
	g, b, _ := newTestClient(t, map[string]string{"api.json": apiJSON([2]string{"5", "completed"})}, nil)
	r := &Report{}
	last := func() string {
		calls := ghCalls(t, b)
		return strings.Fields(calls[len(calls)-1])[3]
	}
	load := func(since string, force bool) {
		t.Helper()
		g.sinceReq = since
		if !g.loadStateReasons(r, force) {
			t.Fatalf("load(%q, %v) failed: %v", since, force, r.Notes)
		}
	}
	load("2026-03-10T00:00:00Z", false)
	load("2026-03-11T00:00:00Z", true)
	if !strings.HasSuffix(last(), "&since=2026-03-10T00:00:00Z") {
		t.Errorf("forced reload with a newer request must keep the cached bound: %s", last())
	}
	load("2026-03-10T00:00:00Z", true)
	if !strings.HasSuffix(last(), "&since=2026-03-10T00:00:00Z") {
		t.Errorf("forced reload with the same bound: %s", last())
	}
	load("2026-03-09T00:00:00Z", true)
	if !strings.HasSuffix(last(), "&since=2026-03-09T00:00:00Z") {
		t.Errorf("forced reload with an older request uses the older bound: %s", last())
	}
	load("", true)
	if strings.Contains(last(), "since") {
		t.Errorf("an unbounded request stays unbounded: %s", last())
	}
}

// The old-gh bound is the retro filename's date minus two days.
func TestClosedOldGHBoundIsTwoDaysBeforeTheRetroDate(t *testing.T) {
	g, b, _ := newTestClient(t, nil, nil)
	if _, ok := g.closedOldGH(&Report{}, "t/retros/2026-03-01-a.md"); !ok {
		t.Fatalf("closedOldGH failed: %v", g.err)
	}
	if g.sinceReq != "2026-02-27T00:00:00Z" {
		t.Errorf("sinceReq = %q, want the date minus two days", g.sinceReq)
	}
	calls := ghCalls(t, b)
	if url := strings.Fields(calls[len(calls)-1])[3]; !strings.HasSuffix(url, "&since=2026-02-27T00:00:00Z") {
		t.Errorf("the listing is bounded by it: %s", url)
	}
}

func TestEnvValueFirstAndLastEntry(t *testing.T) {
	if got := envValue([]string{"A=1"}, "A"); got != "1" {
		t.Errorf("the only entry: %q", got)
	}
	if got := envValue([]string{"A=1", "B=2", "A=3"}, "A"); got != "3" {
		t.Errorf("the last entry wins: %q", got)
	}
	if got := envValue([]string{"A=1", "B=2"}, "A"); got != "1" {
		t.Errorf("an entry at index 0 is read: %q", got)
	}
	if got := envValue([]string{"AB=1"}, "A"); got != "" {
		t.Errorf("a longer name is not the key: %q", got)
	}
}
