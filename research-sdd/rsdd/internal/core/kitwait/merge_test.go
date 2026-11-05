package kitwait

import (
	"strings"
	"testing"
	"time"
)

func TestMergeRetriesAndRefusal(t *testing.T) {
	// degraded once, then the PR shows MERGED
	w := newWorld()
	w.on("pr checks 7", 0, "", 0)
	w.on("pr view 7 --json state", 0, "OPEN\n", 1)
	w.merged()
	w.mg = []mgReply{{3, "merge-gate: degraded: x"}, {0, "allow"}}
	if rc := w.run(""); rc != 0 || len(w.mgCalls) != 2 {
		t.Errorf("rc=%d mg=%d out=%s", rc, len(w.mgCalls), w.out.String())
	}
	if !strings.Contains(w.out.String(), "kit-wait-merge: retry 1/3 (degraded)\n") || len(w.slept) != 1 || w.slept[0] != 30*time.Second {
		t.Errorf("retry note / KIT_MERGE_SLEEP default 30: out=%q slept=%v", w.out.String(), w.slept)
	}

	// degraded every time: three tries, then merge-degraded
	d := newWorld()
	d.on("pr checks 7", 0, "", 0)
	d.on("pr view 7 --json state", 0, "OPEN\n", 0)
	d.mg = []mgReply{{3, "degraded"}}
	if rc := d.run(""); rc != ExitMergeDegraded || len(d.mgCalls) != 3 {
		t.Errorf("rc=%d mg=%d", rc, len(d.mgCalls))
	}
	if !strings.HasSuffix(d.out.String(), "kit-wait-merge: merge-degraded: merge-gate stayed degraded for #7\n") {
		t.Errorf("out = %q", d.out.String())
	}

	// pending: an allow that has not shown MERGED, and the ci_pending refusal, are retried; KIT_MERGE_TRIES bounds them
	p := newWorld()
	p.env["KIT_MERGE_TRIES"] = "2"
	p.on("pr checks 7", 0, "", 0)
	p.on("pr view 7 --json state", 0, "OPEN\n", 0)
	p.mg = []mgReply{{0, "allow"}, {1, "refuse: ci_pending"}}
	if rc := p.run(""); rc != ExitNotMerged || len(p.mgCalls) != 2 {
		t.Errorf("rc=%d mg=%d", rc, len(p.mgCalls))
	}
	if !strings.HasSuffix(p.out.String(), "kit-wait-merge: retry 1/2 (pending)\nrefuse: ci_pending\nkit-wait-merge: retry 2/2 (pending)\nkit-wait-merge: not-merged: #7 is not merged (pending)\n") {
		t.Errorf("out = %q", p.out.String())
	}

	// any other refusal stops at once, with no sleep
	r := newWorld()
	r.on("pr checks 7", 0, "", 0)
	r.on("pr view 7 --json state", 0, "OPEN\n", 0)
	r.mg = []mgReply{{1, "refuse: review_due"}}
	if rc := r.run(""); rc != ExitNotMerged || len(r.mgCalls) != 1 || len(r.slept) != 0 {
		t.Errorf("rc=%d mg=%d slept=%v", rc, len(r.mgCalls), r.slept)
	}
	if !strings.HasSuffix(r.out.String(), "kit-wait-merge: not-merged: #7 is not merged (refused)\n") {
		t.Errorf("out = %q", r.out.String())
	}

	// KIT_MERGE_TRIES=0: the loop never runs and nothing was learned, so the verdict says so
	z := newWorld()
	z.env["KIT_MERGE_TRIES"] = "0"
	z.on("pr checks 7", 0, "", 0)
	if rc := z.run(""); rc != ExitNotMerged || len(z.mgCalls) != 0 {
		t.Errorf("rc=%d mg=%d", rc, len(z.mgCalls))
	}
}

func TestExpectHead(t *testing.T) {
	for _, c := range []struct {
		name, view string
		rc         int
		want       string
	}{
		{"match", "aaa mc1\n", ExitMerged, "kit-wait-merge: merged: #7 (merge commit mc1)\n"},
		{"match without merge commit", "aaa \n", ExitMerged, "kit-wait-merge: merged: #7 (merge commit )\n"},
		{"out of band", "bbb mc1\n", ExitMergedOutOfBand, "kit-wait-merge: merged-out-of-band: #7 is MERGED at head bbb, not the gated head aaa\n"},
		{"unreadable", "", ExitMergeDegraded, "kit-wait-merge: merge-degraded: #7 is MERGED but its head and merge commit could not be read\n"},
	} {
		w := newWorld()
		w.on("pr checks 7", 0, "", 0)
		w.on("pr view 7 --json state", 0, "MERGED\n", 0)
		w.on("pr view 7 --json headRefOid,mergeCommit", 0, c.view, 0)
		w.mg = []mgReply{{0, "allow"}}
		if rc := w.run("aaa"); rc != c.rc || !strings.HasSuffix(w.out.String(), c.want) {
			t.Errorf("%s: rc=%d out=%q", c.name, rc, w.out.String())
		}
	}
	// the state read is retried through kit_retry: a gh blip is not a verdict
	w := newWorld()
	w.on("pr checks 7", 0, "", 0)
	w.on("pr view 7 --json state", 1, "", 1)
	w.merged()
	w.mg = []mgReply{{0, "allow"}}
	if rc := w.run(""); rc != 0 || w.gh.count("pr view 7 --json state") != 2 {
		t.Errorf("rc=%d views=%d", rc, w.gh.count("pr view 7 --json state"))
	}
	if !strings.Contains(w.errb.String(), "kit-wait-merge: retry 1/3 after rc=1: gh pr view 7 --json state -q .state\n") {
		t.Errorf("retry note = %q", w.errb.String())
	}
}

// The retry note of the head/merge-commit read names the whole jq expression (kit-wait-merge.sh), or the words the
// caller gives (the merge train's elided form).
func TestHeadReadRetryNote(t *testing.T) {
	for _, c := range []struct{ words, want string }{
		{"", `kit-wait-merge: retry 1/3 after rc=1: gh pr view 7 --json headRefOid,mergeCommit -q .headRefOid + " " + (.mergeCommit.oid // "")` + "\n"},
		{"custom words", "kit-wait-merge: retry 1/3 after rc=1: custom words\n"},
	} {
		w := newWorld()
		w.on("pr checks 7", 0, "", 0)
		w.merged()
		w.on("pr view 7 --json headRefOid,mergeCommit", 1, "", 1)
		w.on("pr view 7 --json headRefOid,mergeCommit", 0, "aaa mc1\n", 0)
		rc := Run(Opts{Out: &w.out, R: w.gh, Getenv: func(k string) string { return w.env[k] }, Sleep: func(time.Duration) {},
			Wt: "/wt", PR: "7", Base: "origin/main", ExpectHead: "aaa", HeadReadWords: c.words,
			MergeGate: func([]string) (int, string) { return 0, "allow" }})
		if rc != ExitMerged || !strings.Contains(w.errb.String(), c.want) {
			t.Errorf("words %q: rc=%d err=%q, want %q", c.words, rc, w.errb.String(), c.want)
		}
	}
}
