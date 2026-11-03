package reconcile

import (
	"bytes"
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

// The Report fields are the contract session 4 reads (rsdd status show): the counts of Untracked and Tracked,
// Degraded, OutOfScopeMarker and the error text. These tests pin them on real runs.

func runReport(t *testing.T, c dcase) Report {
	t.Helper()
	b := mkBox(t, c)
	rep, err := Run(context.Background(), Options{Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd,
		Env: func(string) string { return "" }})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	return rep
}

func rowIDs(ds []Delta) []string {
	var out []string
	for _, d := range ds {
		out = append(out, d.Row)
	}
	return out
}

func TestReportClassesAreTyped(t *testing.T) {
	rep := runReport(t, dcase{retro: pending + tableHead + rowsOf("1", "2", "3"), cache: sigs("target-foo", "r.md", "2", "9")})
	if got := rowIDs(rep.Tracked); !reflect.DeepEqual(got, []string{"2"}) {
		t.Errorf("Tracked = %v, want [2]", got)
	}
	if got := rowIDs(rep.Untracked); !reflect.DeepEqual(got, []string{"1", "3"}) {
		t.Errorf("Untracked = %v, want [1 3]", got)
	}
	if got := rowIDs(rep.Orphaned); !reflect.DeepEqual(got, []string{"9"}) {
		t.Errorf("Orphaned = %v, want [9]", got)
	}
	if rep.Degraded != "" || rep.OutOfScopeMarker != "" || rep.Failure != "" {
		t.Errorf("a clean audit carries no typed state: %+v", rep)
	}
	if rep.Tracked[0].Retro != "r.md" {
		t.Errorf("Delta.Retro = %q, want the retro base name", rep.Tracked[0].Retro)
	}
}

func TestReportTypedStatesStayDistinct(t *testing.T) {
	deg := runReport(t, dcase{retro: pending + tableHead + rowsOf("1"), cacheMissing: true})
	if deg.Degraded == "" || deg.OutOfScopeMarker != "" || deg.Failure != "" {
		t.Errorf("unreadable cache must be Degraded only: %+v", deg)
	}
	var so, se bytes.Buffer
	if rc := deg.Render(&so, &se); rc != 1 || so.Len() != 0 {
		t.Errorf("degraded Render: rc=%d stdout=%q, want rc=1 and no stdout", rc, so.String())
	}

	oos := runReport(t, dcase{retro: "# retro\n\n## Notes\n\n<!-- review-status: applied -->\n\n" + tableHead + rowsOf("1")})
	if oos.OutOfScopeMarker == "" || oos.Degraded != "" || len(oos.Untracked)+len(oos.Tracked) != 0 {
		t.Errorf("a misplaced marker is OutOfScopeMarker only, nothing classified: %+v", oos)
	}
	so.Reset()
	se.Reset()
	if rc := oos.Render(&so, &se); rc != 0 {
		t.Errorf("out-of-scope marker is a finding, never a failure: rc=%d", rc)
	}

	absent := runReport(t, dcase{noRetro: true})
	if absent.Failure == "" || absent.Degraded != "" {
		t.Errorf("absent-input is Failure, not Degraded: %+v", absent)
	}
}

func TestRunOperationalErrors(t *testing.T) {
	b := mkBox(t, dcase{retro: pending + tableHead + rowsOf("1")})
	base := Options{Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd, Env: noEnv}

	nilCache := base
	nilCache.IssuesCache = nil
	if _, err := Run(context.Background(), nilCache); !errors.Is(err, ErrNotInSlice) {
		t.Errorf("nil IssuesCache: err = %v, want ErrNotInSlice", err)
	}
	noRetro := base
	noRetro.Retro = ""
	if _, err := Run(context.Background(), noRetro); !errors.Is(err, ErrUsage) {
		t.Errorf("empty Retro: err = %v, want ErrUsage", err)
	}
	noKit := base
	noKit.KitRoot = ""
	if _, err := Run(context.Background(), noKit); !errors.Is(err, ErrUsage) {
		t.Errorf("empty KitRoot: err = %v, want ErrUsage", err)
	}
}

func TestRunDeadlineIsWrapped(t *testing.T) {
	b := mkBox(t, dcase{retro: pending + tableHead + rowsOf("1")})
	ctx, cancel := context.WithTimeout(context.Background(), time.Nanosecond)
	defer cancel()
	<-ctx.Done()
	_, err := Run(ctx, Options{Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd, Env: noEnv})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want errors.Is(err, context.DeadlineExceeded)", err)
	}
	_, err = Run(context.Background(), Options{Retro: b.arg, IssuesCache: CacheFile(b.cache), KitRoot: b.root, Cwd: b.cwd, Env: noEnv, Timeout: time.Nanosecond})
	if err != nil && !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Timeout: err = %v, want nil or a wrapped deadline", err)
	}
}

func TestCacheBodiesAndFileAgree(t *testing.T) {
	c := dcase{retro: pending + tableHead + rowsOf("1", "2"), cache: sigs("target-foo", "r.md", "1")}
	b := mkBox(t, c)
	opts := Options{Retro: b.arg, KitRoot: b.root, Cwd: b.cwd, Env: noEnv}
	opts.IssuesCache = CacheFile(b.cache)
	fromFile, err := Run(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	opts.IssuesCache = CacheBodies(c.cache)
	fromBodies, err := Run(context.Background(), opts)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(fromFile, fromBodies) {
		t.Errorf("file cache and in-memory cache differ:\n%+v\n%+v", fromFile, fromBodies)
	}
}

// noEnv is an empty environment: the tests never read the host's.
func noEnv(string) string { return "" }

// Cwd and Env are required inputs (archtest: os.Getwd / os.Getenv only in cli/stdio.go): a caller that forgets
// one gets ErrUsage, never the process's own working directory or environment.
func TestRunRequiresCwdAndEnv(t *testing.T) {
	for name, o := range map[string]Options{
		"no cwd": {Retro: "r.md", KitRoot: "/k", Env: noEnv, IssuesCache: CacheBodies("")},
		"no env": {Retro: "r.md", KitRoot: "/k", Cwd: "/", IssuesCache: CacheBodies("")},
	} {
		if _, err := Run(context.Background(), o); !errors.Is(err, ErrUsage) {
			t.Errorf("%s: err = %v, want ErrUsage", name, err)
		}
	}
}
