package show

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// The cached probes of the ISSUES-DUE gate are answered in process (kit issue #2644): `rsdd retro reconcile` is no
// longer started once per probed retro. These tests run `--next` over REAL retros (delta tables the due computation
// reads), a real kit (research-sdd/TARGETS.md registering the corpus) and a stubbed gh, and record every
// subprocess the gate asks for. What the legacy-world scenarios cannot say, because their reconcile is a canned fake,
// is said here.

const (
	inprocTarget = "tgt"
	inprocHead   = "<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n| # | Change |\n|---|---|\n"
)

// inprocRetro is a pending retro with one delta row per id.
func inprocRetro(ids ...string) string {
	b := inprocHead
	for _, id := range ids {
		b += "| " + id + " | change " + id + " |\n"
	}
	return b
}

// inprocSig is the issue-body signature line of a row of retro name.
func inprocSig(name, id string) string {
	return "Source retro: " + inprocTarget + "/retros/" + name + " · " + id + "\n"
}

type inprocRun struct {
	out        outcome
	reconciled [][]string      // the argv of every `rsdd retro reconcile` the gate asked for
	bounds     []time.Duration // the bound the gate set on each of them
	ghCalls    int
}

// runInproc runs `--next` over an exhausted corpus holding the retros, with the open-issue bodies the batch
// prefetch answers. reverify answers a reconcile that is still started (the per-retro re-verify); nil makes any
// spawn a failure of the test.
func runInproc(t *testing.T, retroFiles files, bodies string, env map[string]string, reverify func(args []string) probeResult) inprocRun {
	t.Helper()
	sc := n5("inproc", "", one("root", "covered", 0, "0"), retroFiles, env)
	root := sc.build(t)
	kit := t.TempDir()
	tb := filepath.Join(kit, "research-sdd", "toolbelt")
	must(t, os.MkdirAll(tb, 0o755))
	must(t, os.WriteFile(filepath.Join(tb, "clean-check.sh"), []byte("#!/bin/sh\n"), 0o755))
	targets := "# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | " + inprocTarget + " | `" + filepath.Join(root, "corpus") + "` |\n"
	must(t, os.WriteFile(filepath.Join(kit, "research-sdd", "TARGETS.md"), []byte(targets), 0o644))

	var res inprocRun
	seamMu.Lock()
	defer seamMu.Unlock()
	oldV, oldG, oldR, oldC := verifyState, ghList, reconcileRun, cleanCheckRun
	defer func() { verifyState, ghList, reconcileRun, cleanCheckRun = oldV, oldG, oldR, oldC }()
	verifyState = func([]string, cli.Stdio) int { return 0 }
	cleanCheckRun = func(string, string, time.Duration, cli.Stdio) probeResult { return probeResult{} }
	ghList = func(gh.Options, ...string) (gh.RunResult, error) {
		res.ghCalls++
		return gh.RunResult{State: gh.StateOK, Stdout: []byte(bodies)}, nil
	}
	oldD := dueRun
	defer func() { dueRun = oldD }()
	dueRun = inprocDue
	reconcileRun = func(args []string, bound time.Duration, _ cli.Stdio) probeResult {
		res.reconciled = append(res.reconciled, args)
		res.bounds = append(res.bounds, bound)
		if reverify == nil {
			t.Errorf("rsdd retro reconcile was started: %q", args)
			return probeResult{}
		}
		return reverify(args)
	}
	e := s5Env{sc.environ(root, t.TempDir(), "/nonexistent-bin"), tb}
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: e.lookup, Environ: func() []string { return e.environ },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: root}
	rc := run([]string{filepath.Join(root, "corpus"), "--next"}, s, syncOr(nextOr(liveSeams, s4Tail)))
	res.out = outcome{rc, strings.ReplaceAll(out.String(), root, "<ROOT>"), strings.ReplaceAll(errb.String(), root, "<ROOT>")}
	return res
}

// A retro whose every open row has an issue in the batch is clean, and nothing is started for it: no
// `rsdd retro reconcile` for the probe (the gate used to start one per retro).
func TestIssuesGateCleanRetrosStartNoReconcile(t *testing.T) {
	r := runInproc(t, retros("a.md", inprocRetro("D1", "D2"), "b.md", inprocRetro("D1")),
		inprocSig("a.md", "D1")+inprocSig("a.md", "D2")+inprocSig("b.md", "D1"), nil, nil)
	if r.out.rc != 0 || r.out.out != stopLine+"\n" || r.out.err != "" {
		t.Errorf("verdict: rc=%d out=%q err=%q, want the clean STOP", r.out.rc, r.out.out, r.out.err)
	}
	if len(r.reconciled) != 0 {
		t.Errorf("reconcile started %d time(s): %q", len(r.reconciled), r.reconciled)
	}
	if r.ghCalls != 1 {
		t.Errorf("batch prefetch ran %d times, want 1", r.ghCalls)
	}
}

// A row with no issue in the batch is re-verified with one live per-retro reconcile (the batch may be capped or
// stale): that run, and only that one, is still started, without the cache. The rows the re-verify reports win.
func TestIssuesGateUntrackedRowIsReverifiedByOneReconcileWithoutCache(t *testing.T) {
	r := runInproc(t, retros("a.md", inprocRetro("D1", "D2"), "b.md", inprocRetro("D1")),
		inprocSig("a.md", "D1")+inprocSig("b.md", "D1"), nil,
		func([]string) probeResult {
			return probeResult{out: "untracked: row D2 — no open issue found for this delta in a.md\n"}
		})
	if want := "ISSUES-DUE | 1 untracked delta(s) in <ROOT>/corpus/retros/a.md — seed: stage-retro-issues.sh <ROOT>/corpus/retros/a.md --apply\n"; r.out.out != want {
		t.Errorf("out=%q, want %q", r.out.out, want)
	}
	if len(r.reconciled) != 1 || len(r.reconciled[0]) != 1 || !strings.HasSuffix(r.reconciled[0][0], "/corpus/retros/a.md") {
		t.Errorf("reconcile argv = %q, want exactly one run of a.md without --issues-cache", r.reconciled)
	}
}

// The re-verify is bounded like every other call of the gate: _IDG_RECONCILE_TIMEOUT_SECS seconds, 15 by default. The
// cached probes no longer spawn, so this is the one place the bound reaches a started reconcile (kit issue #2644).
func TestIssuesGateReverifyIsBoundedByTheReconcileTimeout(t *testing.T) {
	for _, c := range []struct {
		name string
		env  map[string]string
		want time.Duration
	}{
		{"default", nil, 15 * time.Second},
		{"knob", map[string]string{"_IDG_RECONCILE_TIMEOUT_SECS": "7"}, 7 * time.Second},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := runInproc(t, retros("a.md", inprocRetro("D1")), "", c.env, func([]string) probeResult { return probeResult{} })
			if len(r.bounds) != 1 || r.bounds[0] != c.want {
				t.Errorf("reconcile bounds = %v, want exactly [%v]", r.bounds, c.want)
			}
		})
	}
}

// The re-verify clears a batch false negative: the retro is then clean, as before.
func TestIssuesGateReverifyClearsABatchFalseNegative(t *testing.T) {
	r := runInproc(t, retros("a.md", inprocRetro("D1")), "", nil, func([]string) probeResult { return probeResult{} })
	if r.out.out != stopLine+"\n" || len(r.reconciled) != 1 || len(r.reconciled[0]) != 1 {
		t.Errorf("out=%q reconcile=%q, want the clean STOP after one re-verify without --issues-cache", r.out.out, r.reconciled)
	}
}

// A probe that could not look is unverified, named in the words the subprocess failure had: here the degraded
// state of an invalid RECONCILE_ISSUES_LIST_LIMIT (a "degraded:" line is the gh-degraded sentence).
func TestIssuesGateInProcessProbeFailureIsUnverified(t *testing.T) {
	r := runInproc(t, retros("a.md", inprocRetro("D1")), inprocSig("a.md", "D1"),
		map[string]string{"RECONCILE_ISSUES_LIST_LIMIT": "0"}, nil)
	if r.out.out != stopLine+unverified+"\n" || r.out.err != "WARN: could not verify issue coverage (gh degraded) — seed manually\n" || len(r.reconciled) != 0 {
		t.Errorf("out=%q err=%q reconcile=%q", r.out.out, r.out.err, r.reconciled)
	}
}

// A retro with no delta section answers rc 0 and no untracked row: clean, with nothing started.
func TestIssuesGateRetroWithoutRowsIsCleanInProcess(t *testing.T) {
	r := runInproc(t, retros("a.md", "# A\n\nno deltas here\n"), "", nil, nil)
	if r.out.out != stopLine+"\n" || r.out.err != "" || len(r.reconciled) != 0 {
		t.Errorf("out=%q err=%q reconcile=%q", r.out.out, r.out.err, r.reconciled)
	}
}

// A marker outside the leading block classifies nothing: unverified, and still no process.
func TestIssuesGateOutOfScopeMarkerIsUnverifiedInProcess(t *testing.T) {
	r := runInproc(t, retros("a.md", "# A\n\ntext\n<!-- review-status: applied -->\n"), "", nil, nil)
	if r.out.out != stopLine+unverified+"\n" || !strings.Contains(r.out.err, "out-of-scope review-status marker for a.md") || len(r.reconciled) != 0 {
		t.Errorf("out=%q err=%q reconcile=%q", r.out.out, r.out.err, r.reconciled)
	}
}
