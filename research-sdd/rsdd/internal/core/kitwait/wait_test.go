package kitwait

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// fakeGh scripts `gh`: each call is matched on its argument text by the first rule with budget left.
type ghRule struct {
	prefix string
	res    kitmaint.Res
	times  int // 0: unlimited
	hits   int
}

type fakeRunner struct {
	*kitmaint.Runner
	rules []*ghRule
	calls []string
}

func (f *fakeRunner) Gh(_ string, args ...string) kitmaint.Res {
	line := strings.Join(args, " ")
	f.calls = append(f.calls, line)
	for _, r := range f.rules {
		if strings.HasPrefix(line, r.prefix) && (r.times == 0 || r.hits < r.times) {
			r.hits++
			return r.res
		}
	}
	return kitmaint.Res{RC: 97, Err: "unscripted gh " + line}
}

func (f *fakeRunner) count(prefix string) int {
	n := 0
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

type world struct {
	out, errb bytes.Buffer
	slept     []time.Duration
	env       map[string]string
	gh        *fakeRunner
	mg        []mgReply
	mgCalls   [][]string
	polled    int
}

type mgReply struct {
	rc  int
	out string
}

func newWorld() *world {
	w := &world{env: map[string]string{}}
	w.gh = &fakeRunner{}
	w.gh.Runner = &kitmaint.Runner{Err: &w.errb, Sleep: func(d time.Duration) { w.slept = append(w.slept, d) }, Getenv: func(k string) string { return w.env[k] }}
	return w
}

func (w *world) on(prefix string, rc int, out string, times int) {
	w.gh.rules = append(w.gh.rules, &ghRule{prefix: prefix, res: kitmaint.Res{Out: out, RC: rc}, times: times})
}

func (w *world) run(expect string) int {
	i := 0
	return Run(Opts{Out: &w.out, R: w.gh, Getenv: func(k string) string { return w.env[k] },
		Sleep: func(d time.Duration) { w.slept = append(w.slept, d) }, Poll: func() { w.polled++ },
		Wt: "/wt", PR: "7", Base: "origin/main", ExpectHead: expect,
		MergeGate: func(args []string) (int, string) {
			w.mgCalls = append(w.mgCalls, args)
			r := w.mg[len(w.mg)-1]
			if i < len(w.mg) {
				r = w.mg[i]
			}
			i++
			return r.rc, r.out
		}})
}

func (w *world) merged() { w.on("pr view 7 --json state", 0, "MERGED\n", 0) }

func TestMergedSimple(t *testing.T) {
	w := newWorld()
	w.on("pr checks 7", 0, "", 0)
	w.merged()
	w.mg = []mgReply{{0, "a\nb\nc\nd\ne\nf\ng\n"}}
	if rc := w.run(""); rc != ExitMerged {
		t.Fatalf("rc=%d out=%s", rc, w.out.String())
	}
	if want := "c\nd\ne\nf\ng\nkit-wait-merge: merged: #7\n"; w.out.String() != want {
		t.Errorf("out = %q, want the last five merge-gate lines then the merged line", w.out.String())
	}
	if got := strings.Join(w.mgCalls[0], " "); got != "--cwd /wt --base-ref origin/main --merge 7" {
		t.Errorf("merge-gate args = %s", got)
	}
	if w.polled != 1 {
		t.Errorf("poll once per merge-gate run, got %d", w.polled)
	}
	if w.gh.count("pr view 7 --json headRefOid") != 0 {
		t.Error("without --expect-head the head is never read")
	}
}

func TestCIPollingAndFailure(t *testing.T) {
	w := newWorld()
	w.on("pr checks 7", 8, "build pending\n", 2)
	w.on("pr checks 7", 0, "", 0)
	w.merged()
	w.mg = []mgReply{{0, "ok"}}
	if rc := w.run(""); rc != 0 || w.gh.count("pr checks 7") != 3 {
		t.Errorf("rc=%d checks=%d", rc, w.gh.count("pr checks 7"))
	}
	if len(w.slept) != 2 || w.slept[0] != 60*time.Second {
		t.Errorf("pending polls sleep KIT_POLL_SLEEP (default 60): %v", w.slept)
	}

	f := newWorld()
	f.on("pr checks 7", 1, "lint\tfail\t1m\nbuild\tpass\t2m\ntest\tfail\t3m\n", 0)
	if rc := f.run(""); rc != ExitCIFailed || len(f.mgCalls) != 0 {
		t.Errorf("rc=%d mg=%d: a failed check never reaches the merge gate", rc, len(f.mgCalls))
	}
	if want := "lint\tfail\t1m\ntest\tfail\t3m\nkit-wait-merge: ci-failed: a CI check failed for #7\n"; f.out.String() != want {
		t.Errorf("out = %q", f.out.String())
	}
	// the word must be a whole word: "failover" is not a failure; stderr of gh counts too
	g := newWorld()
	g.env["KIT_POLL_MAX"] = "2"
	g.on("pr checks 7", 1, "failover pending\n", 0)
	g.merged()
	g.mg = []mgReply{{0, "ok"}}
	if rc := g.run(""); rc != 0 || g.gh.count("pr checks 7") != 2 {
		t.Errorf("rc=%d checks=%d", rc, g.gh.count("pr checks 7"))
	}
	if !strings.Contains(g.out.String(), "kit-wait-merge: ci-wait: no green result after 2 polls; merge-gate decides\n") {
		t.Errorf("out = %q", g.out.String())
	}
	h := newWorld()
	h.gh.rules = append(h.gh.rules, &ghRule{prefix: "pr checks 7", res: kitmaint.Res{Err: "x fail y", RC: 1}})
	if rc := h.run(""); rc != ExitCIFailed {
		t.Errorf("a fail word on stderr must count: rc=%d", rc)
	}
	z := newWorld()
	z.env["KIT_POLL_MAX"] = "0"
	z.merged()
	z.mg = []mgReply{{0, ""}}
	if rc := z.run(""); rc != 0 || z.gh.count("pr checks") != 0 || !strings.Contains(z.out.String(), "after 0 polls") {
		t.Errorf("KIT_POLL_MAX=0 skips the wait: rc=%d out=%q", rc, z.out.String())
	}
}
