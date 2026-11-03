package reconcile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// Unit tests of the live path. They pin every boundary and boolean the differential reaches only through a
// golden, so a mutant of a comparison fails here by name.

func TestListLimit(t *testing.T) {
	huge := "99999999999999999999999"
	for _, tc := range []struct {
		in   string
		text string
		n    int
		bad  bool
	}{
		{"", "1000", 1000, false},
		{"1", "1", 1, false},
		{"250", "250", 250, false},
		{"007", "007", 7, false},
		{"00", "00", 0, false}, // `case 0` matches only the single digit: "00" passes, as in bash
		{"0", "0", 0, true},
		{"-1", "-1", 0, true},
		{"1a", "1a", 0, true},
		{" 1", " 1", 0, true},
		{huge, huge, int(^uint(0) >> 1), false},
	} {
		text, n, bad := listLimit(func(string) string { return tc.in })
		if text != tc.text || n != tc.n || (bad != "") != tc.bad {
			t.Errorf("listLimit(%q) = (%q, %d, %q), want (%q, %d, bad=%v)", tc.in, text, n, bad, tc.text, tc.n, tc.bad)
		}
		if tc.bad && bad != "degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '"+tc.in+"')" {
			t.Errorf("bad line = %q", bad)
		}
	}
}

func TestCountSepsAndDropSeps(t *testing.T) {
	if n := countSeps("a\n\x1e\nb\n\x1e"); n != 2 {
		t.Errorf("countSeps = %d, want 2", n)
	}
	if n := countSeps("a \x1e\n\x1e b"); n != 0 {
		t.Errorf("a separator inside a line is not a record separator: %d", n)
	}
	if got := dropSeps("a\n\x1e\nb\n\x1e"); got != "a\nb" {
		t.Errorf("dropSeps = %q", got)
	}
	if got := dropSeps("\x1e"); got != "" {
		t.Errorf("dropSeps of a lone separator = %q", got)
	}
}

func TestSubstitutionFirstLineAndMsg(t *testing.T) {
	if got := substitution([]byte("a\x00b\n\n")); got != "ab" {
		t.Errorf("substitution = %q", got)
	}
	if got := firstLine([]byte("one\ntwo")); got != "one" {
		t.Errorf("firstLine = %q", got)
	}
	if got := firstLine([]byte("only")); got != "only" {
		t.Errorf("firstLine of one line = %q", got)
	}
	if withMsg("") != "" || withMsg("x") != " — x" {
		t.Errorf("withMsg: %q %q", withMsg(""), withMsg("x"))
	}
	if asciiLower("AbÄZ-é") != "abÄz-é" {
		t.Errorf("asciiLower touched a non-ASCII letter: %q", asciiLower("AbÄZ-é"))
	}
}

// newTestClient is a ghClient over the stub gh of a live box.
func newTestClient(t *testing.T, files map[string]string, env map[string]string) (*ghClient, *box, *[]time.Duration) {
	t.Helper()
	b := mkBox(t, dcase{retro: pending + tableHead + rowsOf("1"), live: true, gh: files})
	environ := []string{"PATH=" + b.env["PATH"]}
	if env == nil {
		env = map[string]string{}
	}
	var slept []time.Duration
	g := &ghClient{
		ctx: context.Background(), o: gh.Options{Env: environ}, repo: "o/r", limitText: "1000", limit: 1000,
		get:   func(k string) string { return env[k] },
		sleep: func(_ context.Context, d time.Duration) { slept = append(slept, d) },
	}
	return g, b, &slept
}

func ghCalls(t *testing.T, b *box) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(b.root, "gh.log"))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimRight(string(data), "\n"), "\n")
}

func TestRetryPause(t *testing.T) {
	now := func() time.Time { return time.Unix(1000, 0) }
	for _, tc := range []struct {
		name   string
		stderr string
		env    map[string]string
		now    func() time.Time
		want   int // seconds slept; 0 = no wait and no note
	}{
		{"default backoff", "", nil, nil, 2},
		{"backoff from env", "", map[string]string{"RECONCILE_ISSUES_RETRY_BACKOFF": "4"}, nil, 4},
		{"backoff zero is raised to one", "", map[string]string{"RECONCILE_ISSUES_RETRY_BACKOFF": "0"}, nil, 1},
		{"backoff not numeric", "", map[string]string{"RECONCILE_ISSUES_RETRY_BACKOFF": "4s"}, nil, 2},
		{"retry-after", "HTTP 403\nRetry-After: 7\n", nil, nil, 7},
		{"retry-after with equals", "retry-after=9", nil, nil, 9},
		{"retry-after zero is one", "retry-after: 0", nil, nil, 1},
		{"retry-after at the cap", "retry-after: 30", nil, nil, 30},
		{"retry-after above the cap", "retry-after: 31", nil, nil, 30},
		{"retry-after above a lower max", "retry-after: 99", map[string]string{"RECONCILE_ISSUES_RETRY_MAX_WAIT": "5"}, nil, 5},
		{"max wait zero never waits", "retry-after: 99", map[string]string{"RECONCILE_ISSUES_RETRY_MAX_WAIT": "0"}, nil, 0},
		{"max wait not numeric", "retry-after: 99", map[string]string{"RECONCILE_ISSUES_RETRY_MAX_WAIT": "x"}, nil, 30},
		{"retry-after of thirteen digits is no header", "retry-after: 1234567890123", nil, nil, 2},
		{"retry-after of twelve digits is capped", "retry-after: 123456789012", nil, nil, 30},
		{"retry-after followed by text", "retry-after: 7s", nil, nil, 7},
		{"reset header in the future", "x-ratelimit-reset: 1012", nil, now, 12},
		{"reset header, upper case", "X-RateLimit-Reset: 1012", nil, now, 12},
		{"reset header in the past", "x-ratelimit-reset: 900", nil, now, 1},
		{"reset header needs a clock", "x-ratelimit-reset: 1012", nil, nil, 2},
		{"retry-after wins over reset", "x-ratelimit-reset: 1012\nretry-after: 3", nil, now, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			env := tc.env
			if env == nil {
				env = map[string]string{}
			}
			var slept []time.Duration
			g := &ghClient{ctx: context.Background(), get: func(k string) string { return env[k] }, now: tc.now,
				sleep: func(_ context.Context, d time.Duration) { slept = append(slept, d) }}
			r := &Report{}
			g.retryPause(r, []byte(tc.stderr))
			if tc.want == 0 {
				if len(slept) != 0 || len(r.Notes) != 0 {
					t.Fatalf("slept %v, notes %v; want neither", slept, r.Notes)
				}
				return
			}
			if !reflect.DeepEqual(slept, []time.Duration{time.Duration(tc.want) * time.Second}) {
				t.Fatalf("slept %v, want %ds", slept, tc.want)
			}
			wantNote := "note: gh api state_reason listing failed — retrying once in " + itoa(tc.want) + "s"
			if !reflect.DeepEqual(r.Notes, []string{wantNote}) {
				t.Fatalf("notes %q, want %q", r.Notes, wantNote)
			}
		})
	}
}

func TestSleepCtxReturnsWhenTheContextEnds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	start := time.Now()
	sleepCtx(ctx, time.Minute)
	if time.Since(start) > 10*time.Second {
		t.Fatal("sleepCtx outlived a cancelled context")
	}
	sleepCtx(context.Background(), time.Millisecond)
}

// The batched state_reason listing is shared by the run and keyed by the bound it was loaded with (kit issue #1784).
func TestStateReasonListingBounds(t *testing.T) {
	g, b, _ := newTestClient(t, map[string]string{"api.json": apiJSON([2]string{"5", "completed"}, [2]string{"6", ""})}, nil)
	r := &Report{}
	apiCalls := func() int {
		n := 0
		for _, l := range ghCalls(t, b) {
			if strings.HasPrefix(l, "gh api ") {
				n++
			}
		}
		return n
	}
	lastURL := func() string {
		calls := ghCalls(t, b)
		f := strings.Fields(calls[len(calls)-1])
		return f[3]
	}
	load := func(since string, force bool) {
		t.Helper()
		g.sinceReq = since
		if !g.loadStateReasons(r, force) {
			t.Fatalf("load(%q, %v) failed: %v", since, force, r.Notes)
		}
	}
	load("2026-03-10T00:00:00Z", false)
	if apiCalls() != 1 || !strings.HasSuffix(lastURL(), "&since=2026-03-10T00:00:00Z") {
		t.Fatalf("first load: %d calls, url %s", apiCalls(), lastURL())
	}
	load("2026-03-10T00:00:00Z", false) // equal bound: covered
	load("2026-03-11T00:00:00Z", false) // newer bound: covered
	if apiCalls() != 1 {
		t.Fatalf("a covering cache must be reused: %d calls", apiCalls())
	}
	load("2026-03-09T00:00:00Z", false) // older bound: reload with the OLDER one
	if apiCalls() != 2 || !strings.HasSuffix(lastURL(), "&since=2026-03-09T00:00:00Z") {
		t.Fatalf("older bound: %d calls, url %s", apiCalls(), lastURL())
	}
	load("2026-03-10T00:00:00Z", false) // the older listing covers it; the reload never moves the bound forward
	if apiCalls() != 2 {
		t.Fatalf("after an older load, a newer request is covered: %d calls", apiCalls())
	}
	load("", false) // unbounded request against a bounded cache: reload, unbounded
	if apiCalls() != 3 || strings.Contains(lastURL(), "since") {
		t.Fatalf("unbounded request: %d calls, url %s", apiCalls(), lastURL())
	}
	load("2026-03-10T00:00:00Z", false) // "none" covers every bound
	load("", false)
	if apiCalls() != 3 {
		t.Fatalf("an unbounded cache covers everything: %d calls", apiCalls())
	}
	load("2026-03-10T00:00:00Z", true) // force reloads, and an unbounded cache keeps the request unbounded
	if apiCalls() != 4 || strings.Contains(lastURL(), "since") {
		t.Fatalf("force on an unbounded cache: %d calls, url %s", apiCalls(), lastURL())
	}
	g.repo = "o/other" // a listing never resolves another repository's issues
	load("", false)
	if apiCalls() != 5 || !strings.Contains(lastURL(), "repos/o/other/") {
		t.Fatalf("another repo must reload: %d calls, url %s", apiCalls(), lastURL())
	}
}

func TestStateReasonOf(t *testing.T) {
	g, b, _ := newTestClient(t, map[string]string{"api.json": apiJSON([2]string{"5", "completed"}, [2]string{"6", ""}, [2]string{"5", "not_planned"}, [2]string{"15", "not_planned"})}, nil)
	r := &Report{}
	if sr, found, ok := g.stateReasonOf(r, "5"); sr != "completed" || !found || !ok {
		t.Errorf("5: %q %v %v (the first match wins)", sr, found, ok)
	}
	if sr, found, ok := g.stateReasonOf(r, "6"); sr != "" || !found || !ok {
		t.Errorf("6 (null reason): %q %v %v", sr, found, ok)
	}
	if sr, found, ok := g.stateReasonOf(r, "1"); found || !ok || sr != "" {
		t.Errorf("1 is a different number than 15: %q %v %v", sr, found, ok)
	}
	api := 0
	for _, l := range ghCalls(t, b) {
		if strings.HasPrefix(l, "gh api ") {
			api++
		}
	}
	if api != 2 {
		t.Errorf("one load plus ONE forced reload for the missing issue, got %d api calls", api)
	}
	g2, _, _ := newTestClient(t, map[string]string{"api.rc": "1"}, nil)
	if _, _, ok := g2.stateReasonOf(&Report{}, "5"); ok {
		t.Error("a failed listing must not read as found or missing")
	}
}

func TestLoadStateReasonsFailsAfterOneRetry(t *testing.T) {
	g, b, slept := newTestClient(t, map[string]string{"api.rc": "1", "api.err": "boom\nmore\n"}, nil)
	r := &Report{}
	if g.loadStateReasons(r, false) {
		t.Fatal("must fail")
	}
	if len(*slept) != 1 {
		t.Errorf("one pause between the two tries, none after the last: %v", *slept)
	}
	if got := r.Degraded; got != "degraded: gh api state_reason listing failed (this gh has no stateReason --json field) — boom" {
		t.Errorf("Degraded = %q", got)
	}
	if n := len(ghCalls(t, b)); n != 2 {
		t.Errorf("%d api calls, want 2", n)
	}
}

func TestGHClientStopsWhenTheContextEnds(t *testing.T) {
	g, b, _ := newTestClient(t, nil, nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	g.ctx = ctx
	if _, ok := g.run("auth", "status"); ok || !errors.Is(g.err, context.Canceled) {
		t.Errorf("run after cancel: ok=%v err=%v", ok, g.err)
	}
	if len(ghCalls(t, b)) != 0 {
		t.Error("gh must not be started once the context has ended")
	}
}

func TestProbeGH(t *testing.T) {
	_, bad, _ := newTestClient(t, map[string]string{"auth.rc": "1"}, nil)
	line, err := ProbeGH(gh.Options{Env: []string{"PATH=" + bad.env["PATH"]}})
	if err != nil || line != "degraded: gh is not authenticated — run 'gh auth login'" {
		t.Errorf("not authenticated: %q %v", line, err)
	}
	_, good, _ := newTestClient(t, nil, nil)
	if line, err := ProbeGH(gh.Options{Env: []string{"PATH=" + good.env["PATH"]}}); err != nil || line != "" {
		t.Errorf("authenticated: %q %v", line, err)
	}
	empty := t.TempDir()
	line, err = ProbeGH(gh.Options{Env: []string{"PATH=" + empty}})
	if err != nil || line != "degraded: gh not found on PATH — install gh CLI to use reconcile-issues" {
		t.Errorf("missing: %q %v", line, err)
	}
}

func TestLoadCache(t *testing.T) {
	ctx := context.Background()
	opts := func(b *box, extra ...string) gh.Options {
		return gh.Options{Env: append([]string{"PATH=" + b.env["PATH"]}, extra...)}
	}
	_, b, _ := newTestClient(t, map[string]string{"open.json": openJSON("Source retro: t/retros/r.md · 1", "Source retro: t/retros/r.md · 2")}, nil)
	c, err := LoadCache(ctx, opts(b), "")
	if err != nil {
		t.Fatal(err)
	}
	if !c.prefetched {
		t.Error("a prefetched cache must say so, Run re-verifies it")
	}
	if got, _ := c.read(); got != "Source retro: t/retros/r.md · 1\nSource retro: t/retros/r.md · 2" {
		t.Errorf("bodies = %q", got)
	}
	if calls := ghCalls(t, b); len(calls) != 1 || !strings.Contains(calls[0], "--repo "+DefaultRepo+" --state open --limit 1000 --json body") || strings.Contains(calls[0], "--search") {
		t.Errorf("one unfiltered listing of the default repo, got %q", calls)
	}
	// RECONCILE_ISSUES_LIST_LIMIT: a reply that fills it is an error, never a partial cache.
	if _, err := LoadCache(ctx, opts(b, "RECONCILE_ISSUES_LIST_LIMIT=2"), "o/r"); err == nil || !strings.Contains(err.Error(), "returned 2 results = the --limit 2 cap") {
		t.Errorf("capped listing: %v", err)
	}
	if _, err := LoadCache(ctx, opts(b, "RECONCILE_ISSUES_LIST_LIMIT=3"), "o/r"); err != nil {
		t.Errorf("under the cap: %v", err)
	}
	if _, err := LoadCache(ctx, opts(b, "RECONCILE_ISSUES_LIST_LIMIT=x"), "o/r"); err == nil || !strings.Contains(err.Error(), "must be a positive integer") {
		t.Errorf("bad limit: %v", err)
	}
	_, fail, _ := newTestClient(t, map[string]string{"list-open.rc": "1", "list-open.err": "HTTP 500\n"}, nil)
	if _, err := LoadCache(ctx, opts(fail), "o/r"); err == nil || !strings.Contains(err.Error(), "gh issue list failed (exit 1) — HTTP 500") {
		t.Errorf("failed listing: %v", err)
	}
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := LoadCache(cctx, opts(b), "o/r"); !errors.Is(err, context.Canceled) {
		t.Errorf("cancelled: %v", err)
	}
	if got := envValue([]string{"A=1", "A=2", "B=3"}, "A"); got != "2" {
		t.Errorf("the last entry wins: %q", got)
	}
}

// A batch cache is re-verified: only when it reports untracked rows, and only for a prefetched one.
func TestRunReverifiesAPrefetchedCache(t *testing.T) {
	retro := pending + tableHead + rowsOf("1", "2")
	stale := CacheBodies("Source retro: target-foo/retros/r.md · 1")
	stale.prefetched = true
	fresh := openJSON("Source retro: target-foo/retros/r.md · 1", "Source retro: target-foo/retros/r.md · 2")
	run := func(t *testing.T, files map[string]string, cache *Cache, all bool) (Report, []string) {
		t.Helper()
		b := mkBox(t, dcase{retro: retro, live: true, gh: files})
		o := Options{Retro: b.arg, IssuesCache: cache, KitRoot: b.root, Cwd: b.cwd, All: all,
			GH:  gh.Options{Env: []string{"PATH=" + b.env["PATH"]}},
			Env: func(k string) string { return "" }}
		rep, err := Run(context.Background(), o)
		if err != nil {
			t.Fatal(err)
		}
		return rep, ghCalls(t, b)
	}
	rep, calls := run(t, map[string]string{"open.json": fresh}, stale, false)
	if len(rep.Untracked) != 0 || len(rep.Tracked) != 2 {
		t.Errorf("the live answer replaces the stale batch: tracked=%v untracked=%v", rep.Tracked, rep.Untracked)
	}
	if len(calls) != 1 || !strings.Contains(calls[0], "--state open") || !strings.Contains(calls[0], "--search") {
		t.Errorf("one per-retro query, got %q", calls)
	}
	if len(rep.Notes) != 0 {
		t.Errorf("the discarded first pass leaves no notes: %q", rep.Notes)
	}

	full := CacheBodies("Source retro: target-foo/retros/r.md · 1\nSource retro: target-foo/retros/r.md · 2")
	full.prefetched = true
	if rep, calls = run(t, map[string]string{"open.json": "[]"}, full, false); len(calls) != 0 || len(rep.Tracked) != 2 {
		t.Errorf("a batch without untracked rows is the answer: tracked=%v calls=%q", rep.Tracked, calls)
	}
	plain := CacheBodies("Source retro: target-foo/retros/r.md · 1")
	if rep, calls = run(t, map[string]string{"open.json": fresh}, plain, false); len(calls) != 0 || len(rep.Untracked) != 1 {
		t.Errorf("a cache the caller supplied is never re-verified: untracked=%v calls=%q", rep.Untracked, calls)
	}
	if _, calls = run(t, map[string]string{"open.json": fresh}, stale, true); len(calls) != 0 {
		t.Errorf("--all never re-verifies: %q", calls)
	}
}

func TestRunOptionsAreChecked(t *testing.T) {
	b := mkBox(t, dcase{retro: pending + tableHead + rowsOf("1")})
	base := Options{Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd, Env: noEnv}
	allNoRetro := base
	allNoRetro.Retro, allNoRetro.All = "", true
	if _, err := Run(context.Background(), allNoRetro); err != nil {
		t.Errorf("--all needs no retro: %v", err)
	}
	for name, mut := range map[string]func(*Options){
		"no retro": func(o *Options) { o.Retro = "" }, "no kit": func(o *Options) { o.KitRoot = "" },
		"no cwd": func(o *Options) { o.Cwd = "" }, "no env": func(o *Options) { o.Env = nil },
	} {
		o := base
		mut(&o)
		if _, err := Run(context.Background(), o); !errors.Is(err, ErrUsage) {
			t.Errorf("%s: %v, want ErrUsage", name, err)
		}
	}
	bad := base
	bad.Env = func(k string) string {
		if k == "RECONCILE_ISSUES_LIST_LIMIT" {
			return "zero"
		}
		return ""
	}
	rep, err := Run(context.Background(), bad)
	if err != nil || rep.Degraded == "" || rep.Failure != "" {
		t.Errorf("a bad limit is a degraded Report, not an error: %+v %v", rep, err)
	}
	slow := base
	slow.Timeout = time.Nanosecond
	if _, err := Run(context.Background(), slow); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("Timeout: %v, want a wrapped deadline", err)
	}
	if rep, err := Run(context.Background(), base); err != nil || rep.Untracked == nil {
		t.Errorf("no Timeout means no deadline: %+v %v", rep, err)
	}
}

func TestFleetLineAndRender(t *testing.T) {
	f := Fleet{Tracked: 1, Untracked: 2, Shipped: 3, Borderline: 4, Regressed: 5, Orphaned: 6, Degraded: 7, OutOfScope: 8, Retros: 9}
	if got, want := f.Line(), "fleet-summary: tracked=1 untracked=2 shipped=3 borderline=4 regressed=5 orphaned=6 degraded=7 out-of-scope=8 retros=9"; got != want {
		t.Errorf("Line = %q", got)
	}
	var so, se strings.Builder
	if rc := (Report{Fleet: &Fleet{Degraded: 1}}).Render(&so, &se); rc != 1 {
		t.Errorf("a degraded retro in the fleet fails the run: rc=%d", rc)
	}
	if rc := (Report{Fleet: &Fleet{OutOfScope: 3, Untracked: 2}}).Render(&so, &se); rc != 0 {
		t.Errorf("findings never fail the run: rc=%d", rc)
	}
	if !(&Report{ancDegraded: true}).failed() || !(&Report{Degraded: "x"}).failed() || (&Report{}).failed() {
		t.Error("failed() is Degraded or ancDegraded")
	}
}

// The command resolves the kit root from the toolbelt: relative to the working directory, through symlinks.
func TestKitRootOf(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "kit", "research-sdd", "toolbelt")
	mustMkdir(t, real)
	mustWrite(t, filepath.Join(real, "reconcile-issues.sh"), "#!/bin/sh\n")
	link := filepath.Join(root, "link")
	must(t, os.Symlink(real, link))
	var errs []string
	errf := func(f string, a ...any) { errs = append(errs, f) }
	wantKit := filepath.Join(root, "kit")
	for name, tb := range map[string]string{"absolute": real, "through a symlink": link, "relative to cwd": "link"} {
		got, ok := kitRootOf(cli.Stdio{Cwd: root, Env: func(string) string { return "" }}, tb, errf)
		if !ok || got != wantKit {
			t.Errorf("%s: %q %v, want %q", name, got, ok, wantKit)
		}
	}
	// No --toolbelt: the kit resolution (RESEARCH_SDD_KIT).
	env := func(k string) string {
		if k == "RESEARCH_SDD_KIT" {
			return filepath.Join(root, "kit", "research-sdd")
		}
		return ""
	}
	if got, ok := kitRootOf(cli.Stdio{Cwd: root, Env: env}, "", errf); !ok || got != wantKit {
		t.Errorf("kit resolution: %q %v", got, ok)
	}
	if _, ok := kitRootOf(cli.Stdio{Cwd: root, Env: func(string) string { return "" }}, "", errf); ok {
		t.Error("no kit anywhere must fail")
	}
}

func TestRunCommandWithoutAToolbeltFailsWithoutAKit(t *testing.T) {
	var so, se strings.Builder
	s := cli.Stdio{Out: &so, Err: &se, Cwd: t.TempDir(), Env: func(string) string { return "" }}
	b := mkBox(t, dcase{retro: pending + tableHead + rowsOf("1")})
	if rc := RunCommand([]string{"--issues-cache", b.cache, b.arg}, s); rc != 1 || !strings.Contains(se.String(), "reconcile-issues: cannot find the kit toolbelt") {
		t.Errorf("rc=%d stderr=%q", rc, se.String())
	}
	if Command.Group != "retro" || Command.Name != "reconcile" || Command.Run == nil {
		t.Errorf("registry entry: %+v", Command)
	}
}
