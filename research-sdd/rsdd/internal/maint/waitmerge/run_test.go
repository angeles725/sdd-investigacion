package waitmerge

import (
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

func TestPollsRetriesAndMerges(t *testing.T) {
	w := kitworld.New(t)
	w.Rule("gh", "pr checks*", 8, "pr-checks-pending.txt", 2, "")
	w.Rule("gh", "pr checks*", 0, "pr-checks-pass.txt", 0, "")
	w.Rule("gh", "pr view*", 1, "", 1, "")
	happy(w)
	r := goRun(t, w, []string{w.Wt, "7"})
	if r.rc != 0 || !strings.HasSuffix(r.out, "merge-gate: merged: PR #7 (head=abc1234 cwd=/x)\nkit-wait-merge: merged: #7\n") {
		t.Fatalf("%+v", r)
	}
	if count(w.Calls(), "gh pr checks 7") != 3 || count(w.Calls(), "gh pr view") != 2 {
		t.Errorf("calls = %q: pending polled twice more, the gh blip on pr view retried once", w.Calls())
	}
	if !strings.Contains(r.err, "kit-wait-merge: retry 1/3 after rc=1: gh pr view 7 --json state -q .state\n") {
		t.Errorf("stderr = %q", r.err)
	}
	want := "merge-gate.sh --cwd " + w.Wt + " --base-ref origin/main --merge 7"
	if !strings.Contains(w.Calls(), want+"\n") {
		t.Errorf("merge gate call: %q", w.Calls())
	}
	// --base-ref reaches the merge gate
	w2 := kitworld.New(t)
	happy(w2)
	goRun(t, w2, []string{"--base-ref", "up/dev", w2.Wt, "7"})
	if !strings.Contains(w2.Calls(), "--base-ref up/dev --merge 7\n") {
		t.Errorf("calls = %q", w2.Calls())
	}
}

func TestTypedExitStates(t *testing.T) {
	for _, c := range []struct {
		name  string
		rules func(w *kitworld.World)
		rc    int
		line  string
		mg    int // expected merge-gate calls
	}{
		{"ci failed", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 1, "pr-checks-fail.txt", 0, "") }, 17, "kit-wait-merge: ci-failed: a CI check failed for #7", 0},
		{"degraded once then merged", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 3, "merge-gate-degraded.txt", 1, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 1, "")
		}, 0, "kit-wait-merge: merged: #7", 2},
		{"degraded forever", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 3, "merge-gate-degraded.txt", 0, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 0, "")
		}, 18, "kit-wait-merge: merge-degraded: merge-gate stayed degraded for #7", 3},
		{"review due refused at once", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 1, "merge-gate-review-due.txt", 0, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 0, "")
		}, 19, "kit-wait-merge: not-merged: #7 is not merged (refused)", 1},
	} {
		w := kitworld.New(t)
		c.rules(w)
		happy(w)
		r := goRun(t, w, []string{w.Wt, "7"})
		if r.rc != c.rc || !strings.Contains(r.out, c.line+"\n") || count(w.Calls(), "merge-gate.sh") != c.mg {
			t.Errorf("%s: %+v mg=%d", c.name, r, count(w.Calls(), "merge-gate.sh"))
		}
	}
}

func TestExpectHead(t *testing.T) {
	for _, c := range []struct {
		name, fixture string
		rc            int
		line          string
	}{
		{"gated head merged", "pr-info-match.txt", 0, "kit-wait-merge: merged: #7 (merge commit mc1)"},
		{"no merge commit yet", "pr-info-nomc.txt", 0, "kit-wait-merge: merged: #7 (merge commit )"},
		{"another head merged", "pr-info-oob.txt", 33, "kit-wait-merge: merged-out-of-band: #7 is MERGED at head deadbeef, not the gated head abc1234"},
		{"unreadable", "empty.txt", 18, "kit-wait-merge: merge-degraded: #7 is MERGED but its head and merge commit could not be read"},
	} {
		w := kitworld.New(t)
		w.Rule("gh", "pr view 7 --json headRefOid*", 0, c.fixture, 0, "")
		happy(w)
		r := goRun(t, w, []string{"--expect-head", "abc1234", w.Wt, "7"})
		if r.rc != c.rc || !strings.HasSuffix(r.out, c.line+"\n") {
			t.Errorf("%s: %+v", c.name, r)
		}
	}
	// without --expect-head the head is never read
	w := kitworld.New(t)
	happy(w)
	if r := goRun(t, w, []string{w.Wt, "7"}); r.rc != 0 || strings.Contains(w.Calls(), "headRefOid") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}

func TestDegradedStates(t *testing.T) {
	w := kitworld.New(t)
	w.Drop("gh")
	r := goRun(t, w, []string{w.Wt, "7"})
	if r.rc != 3 || r.out != "kit-wait-merge: degraded: missing runtime dependency: gh\n" || r.err != "DEGRADED: missing runtime dependency: gh\n" || w.Calls() != "" {
		t.Errorf("no gh: %+v calls=%q", r, w.Calls())
	}
	// a KIT_MERGE_GATE that is not a file is the same typed state, before any call
	w2 := kitworld.New(t)
	happy(w2)
	r = goRunIn(w2, w2.Wt, []string{w2.Wt, "7"}, "", "KIT_MERGE_GATE="+w2.Dir+"/absent.sh")
	if r.rc != 3 || r.out != "kit-wait-merge: degraded: merge-gate.sh not found: "+w2.Dir+"/absent.sh\n" || w2.Calls() != "" ||
		r.err != "DEGRADED: merge-gate.sh not found: "+w2.Dir+"/absent.sh\n" {
		t.Errorf("no merge gate: %+v calls=%q", r, w2.Calls())
	}
	// a directory is not a file either
	r = goRunIn(w2, w2.Wt, []string{w2.Wt, "7"}, "", "KIT_MERGE_GATE="+w2.Dir)
	if r.rc != 3 {
		t.Errorf("a directory as the merge gate: %+v", r)
	}
	// usage wins over a missing dependency
	w3 := kitworld.New(t)
	w3.Drop("gh")
	if r = goRun(t, w3, []string{w3.Dir + "/nope", "7"}); r.rc != 2 {
		t.Errorf("usage before degraded: %+v", r)
	}
}

func TestWithoutKitMergeGateTheBinaryRunsItsOwnGate(t *testing.T) {
	w := kitworld.New(t)
	self := w.Dir + "/rsdd"
	if err := os.Symlink(w.Fix+"/shim.sh", self); err != nil {
		t.Fatal(err)
	}
	w.Rule("rsdd", "gate merge*", 0, "merge-gate-merged.txt", 0, "")
	w.Rule("gh", "pr checks*", 0, "pr-checks-pass.txt", 0, "")
	w.Rule("gh", "pr view*", 0, "pr-state-merged.txt", 0, "")
	r := goRunIn(w, w.Wt, []string{w.Wt, "7"}, self)
	if r.rc != 0 || !strings.Contains(w.Calls(), "rsdd gate merge --cwd "+w.Wt+" --base-ref origin/main --merge 7\n") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
	// an empty KIT_MERGE_GATE is "unset" (${VAR:-default})
	w2 := kitworld.New(t)
	self2 := w2.Dir + "/rsdd"
	_ = os.Symlink(w2.Fix+"/shim.sh", self2)
	w2.Rule("rsdd", "gate merge*", 0, "merge-gate-merged.txt", 0, "")
	w2.Rule("gh", "pr checks*", 0, "pr-checks-pass.txt", 0, "")
	w2.Rule("gh", "pr view*", 0, "pr-state-merged.txt", 0, "")
	if r = goRunIn(w2, w2.Wt, []string{w2.Wt, "7"}, self2, "KIT_MERGE_GATE="); r.rc != 0 || count(w2.Calls(), "rsdd gate merge") != 1 {
		t.Errorf("empty knob: %+v calls=%q", r, w2.Calls())
	}
}

func TestRelativeWorktreeIsMadeAbsolute(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	extra := mergeGateEnv(t, w)
	r := goRunIn(w, w.Dir, []string{"wt", "7"}, "", extra)
	if r.rc != 0 || !strings.Contains(w.Calls(), "merge-gate.sh --cwd "+w.Wt+" --base-ref") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}
