package prpipeline

import (
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// merge-base --is-ancestor: 0 = up to date (no merge), 1 = behind (merge), anything above 1 = the ref is unusable.
func TestRestackReadsTheAncestorCheckExactly(t *testing.T) {
	for _, c := range []struct {
		rc     int
		want   int
		merged bool
	}{{0, 0, false}, {1, 0, true}, {2, 23, false}, {128, 23, false}} {
		w := kitworld.New(t)
		w.Rule("git", "*merge-base --is-ancestor*", c.rc, "", 0, "")
		happy(w)
		r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"})
		if r.rc != c.want || strings.Contains(w.Calls(), "merge -q --no-edit") != c.merged {
			t.Errorf("ancestor rc %d: exit %d (want %d), merged=%v: %q", c.rc, r.rc, c.want, strings.Contains(w.Calls(), "merge -q"), r.out)
		}
		if c.want == 23 && r.out != "kit-pr-pipeline: bad-base-ref: #7: origin/main does not resolve (git merge-base rc="+strconv.Itoa(c.rc)+")\n" {
			t.Errorf("bad-base-ref text: %q", r.out)
		}
	}
}

// The merge gate: KIT_MERGE_GATE names a script (made absolute against the worktree), unset means the
// rsdd binary's own `gate merge`.
func TestMergeGateScriptResolution(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	prepare(t, w) // merge-gate.sh in the case dir, run-all.sh in the worktree
	start, drive := fakes()
	s, o, _ := w.Stdio(w.Dir, "KIT_MERGE_GATE=../merge-gate.sh") // relative: resolved from the worktree (w.Dir/wt), not the caller
	rc := run([]string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, s, deps{start: start, drive: drive, sleep: func(time.Duration) {}})
	if rc != 0 || !strings.Contains(w.Calls(), "merge-gate.sh --cwd "+w.Wt+" --base-ref origin/main --merge 7") {
		t.Errorf("relative script: rc %d out %q calls %q", rc, o.String(), w.Calls())
	}

	w2 := kitworld.New(t)
	happy(w2)
	w2.Rule("rsdd", "gate merge*", 0, "merge-gate-merged.txt", 0, "")
	d := w2.Wt + "/research-sdd/toolbelt/tests"
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(d+"/run-all.sh", []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	self := w2.Dir + "/rsdd"
	if err := os.Symlink(w2.Fix+"/shim.sh", self); err != nil {
		t.Fatal(err)
	}
	s2, o2, _ := w2.Stdio(w2.Wt)
	rc = run([]string{"--state-dir", w2.Dir + "/st", w2.Wt, "7", "b"}, s2, deps{start: start, drive: drive, sleep: func(time.Duration) {}, self: self})
	if rc != 0 || !strings.Contains(w2.Calls(), "rsdd gate merge --cwd "+w2.Wt+" --base-ref origin/main --merge 7") {
		t.Errorf("default gate: rc %d out %q calls %q", rc, o2.String(), w2.Calls())
	}
}
