package show

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

// The terminal clean-check runs core/cleancheck in process (kit #2549). One test per trap of the old subprocess.

var ccOn = map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}

func ccStub(r cleancheck.Result) gateStubs {
	return gateStubs{cc: func(context.Context, cleancheck.Options) cleancheck.Result { return r }}
}

func ccLines(streams ...cleancheck.Stream) []cleancheck.Line {
	texts := []string{"first", "second", "third"}
	var ls []cleancheck.Line
	for i, s := range streams {
		ls = append(ls, cleancheck.Line{Stream: s, Text: texts[i]})
	}
	return ls
}

// (a) clean is one INFO line.
func TestCleanWarnClean(t *testing.T) {
	o, _ := runStubbed(t, nil, ccOn, ccStub(cleancheck.Result{}))
	if want := "INFO: clean-check: clean at terminal STOP\n"; o.err != want {
		t.Errorf("stderr %q, want %q", o.err, want)
	}
}

// (b) findings: the header, then one WARN per line in print order (stdout and stderr interleaved as printed).
func TestCleanWarnFindingsInPrintOrder(t *testing.T) {
	r := cleancheck.Result{Verdict: cleancheck.Findings, Exit: 1, Lines: ccLines(cleancheck.Err, cleancheck.Out, cleancheck.Err)}
	o, _ := runStubbed(t, nil, ccOn, ccStub(r))
	want := "WARN: clean-check: findings at terminal STOP — resolve or declare in <target>/.research-sdd/keep.txt before closing\n" +
		"WARN: clean-check: first\nWARN: clean-check: second\nWARN: clean-check: third\n"
	if o.err != want {
		t.Errorf("stderr %q, want %q", o.err, want)
	}
}

// (c) a timed-out check names the bound and claims nothing; a real Check under an expired deadline does the same.
func TestCleanWarnTimedOut(t *testing.T) {
	want := "WARN: clean-check: unverifiable (timed out after 7s) — terminal no-garbage check NOT confirmed\n"
	env := map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0", "RSDD_STATUS_CLEAN_CHECK_TIMEOUT": "7"}
	o, _ := runStubbed(t, nil, env, ccStub(cleancheck.Result{Verdict: cleancheck.TimedOut, Exit: 124}))
	if o.err != want {
		t.Errorf("stub: stderr %q, want %q", o.err, want)
	}
	expired := gateStubs{cc: func(_ context.Context, o cleancheck.Options) cleancheck.Result {
		cx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
		defer cancel()
		return cleancheck.Check(cx, o)
	}}
	o, _ = runStubbed(t, nil, env, expired)
	if o.err != want || strings.Contains(o.err, "clean at terminal STOP") {
		t.Errorf("real Check, expired deadline: stderr %q, want %q and no clean claim", o.err, want)
	}
}

// (d) a refused or degraded run is unverifiable and names the last line.
func TestCleanWarnRefusedAndDegraded(t *testing.T) {
	for _, c := range []struct {
		v    cleancheck.Verdict
		exit int
	}{{cleancheck.Refused, 2}, {cleancheck.Degraded, 3}} {
		r := cleancheck.Result{Verdict: c.v, Exit: c.exit, Lines: ccLines(cleancheck.Out, cleancheck.Err)}
		o, _ := runStubbed(t, nil, ccOn, ccStub(r))
		want := "WARN: clean-check: unverifiable (exit " + string(rune('0'+c.exit)) + ": second) — terminal no-garbage check NOT confirmed\n"
		if o.err != want {
			t.Errorf("exit %d: stderr %q, want %q", c.exit, o.err, want)
		}
	}
}

// (e) the deadline handed to Check is RSDD_STATUS_CLEAN_CHECK_TIMEOUT (default 20 s), normalised as before.
func TestCleanWarnDeadlineIsTheBound(t *testing.T) {
	for _, c := range []struct {
		val  string
		want time.Duration
	}{{"", 20}, {"abc", 20}, {"0", 20}, {"5", 5}, {"010", 10}, {"99999999999999999999", 1 << 30}} {
		var left time.Duration
		var has bool
		st := gateStubs{cc: func(cx context.Context, _ cleancheck.Options) cleancheck.Result {
			dl, ok := cx.Deadline()
			has, left = ok, time.Until(dl)
			return cleancheck.Result{}
		}}
		runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0", "RSDD_STATUS_CLEAN_CHECK_TIMEOUT": c.val}, st)
		want := c.want * time.Second
		if !has || left > want || left < want-5*time.Second {
			t.Errorf("TIMEOUT=%q: deadline present=%v remaining %v, want about %v", c.val, has, left, want)
		}
	}
}

// (f) RSDD_STATUS_NO_CLEAN_CHECK=1 calls nothing.
func TestCleanWarnSkippedCallsNothing(t *testing.T) {
	called := false
	st := gateStubs{cc: func(context.Context, cleancheck.Options) cleancheck.Result { called = true; return cleancheck.Result{} }}
	o, _ := runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "1"}, st)
	if called || o.err != "" {
		t.Errorf("called=%v stderr %q, want neither", called, o.err)
	}
}

// (g) the Options: Target, Env and an absolute Cwd and a clock; Tmp, Scratchpad and UID are left for Check to read from Env.
func TestCleanWarnOptions(t *testing.T) {
	var got cleancheck.Options
	st := gateStubs{cc: func(_ context.Context, o cleancheck.Options) cleancheck.Result { got = o; return cleancheck.Result{} }}
	_, root := runStubbed(t, nil, map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0", "TMPDIR": "/x/tmp", "CLEAN_CHECK_UID": "42"}, st)
	if got.Target != filepath.Join(root, "corpus") || got.Cwd != root || !filepath.IsAbs(got.Cwd) || got.Now == nil {
		t.Errorf("target %q cwd %q now-nil=%v", got.Target, got.Cwd, got.Now == nil)
	}
	if got.Tmp != "" || got.Scratchpad != "" || got.UID != "" || got.StaleHours != (cleancheck.Age{}) || got.BackupDays != (cleancheck.Age{}) {
		t.Errorf("Tmp/Scratchpad/UID/ages must stay unset: %+v", got)
	}
	if !slices.Contains(got.Env, "TMPDIR=/x/tmp") || !slices.Contains(got.Env, "CLEAN_CHECK_UID=42") {
		t.Errorf("Env must carry the caller's TMPDIR and CLEAN_CHECK_UID, got %v", got.Env)
	}
}

// (h) no clean-check.sh is started, even when the toolbelt holds one and the real Check runs.
func TestCleanWarnStartsNoScript(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "ran")
	_, _ = runStubbed(t, nil, ccOn, gateStubs{marker: marker, cc: cleancheck.Check})
	if _, err := os.Stat(marker); err == nil {
		t.Error("clean-check.sh ran: the check must be in process")
	}
}
