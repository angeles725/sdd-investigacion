package prpipeline

import (
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

func TestHappyPathOrderOfCalls(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", "--consent", "granted", w.Wt, "7", "feat/x"})
	if r.rc != 0 || !strings.HasSuffix(r.out, "kit-pr-pipeline: merged: #7\n") {
		t.Fatalf("%+v", r)
	}
	var order []string
	for _, l := range strings.Split(gitDirFlag.ReplaceAllString(w.Calls(), "git "), "\n") {
		for _, p := range []string{"git status", "git fetch", "git merge-base", "git push", "git rev-parse", "RDDSTART", "RDDDRIVE", "RUNALL", "gh pr checks", "merge-gate.sh"} {
			if strings.HasPrefix(l, p) {
				order = append(order, p)
				break
			}
		}
	}
	want := "git status,git fetch,git merge-base,git push,git rev-parse,RDDSTART,RDDDRIVE,git rev-parse,RUNALL,gh pr checks,merge-gate.sh"
	if got := strings.Join(order, ","); !strings.HasPrefix(got, want) {
		t.Errorf("order = %s\nwant prefix %s", got, want)
	}
	if !strings.Contains(w.Calls(), "RDDSTART --base-ref origin/main --consent granted "+w.Wt+" "+w.Dir+"/st/rdd-7.json\n") {
		t.Errorf("rdd-start args: %q", w.Calls())
	}
	if !strings.Contains(w.Calls(), "RUNALL -j 4 --prove-teeth\n") {
		t.Errorf("default gate: %q", w.Calls())
	}
}

func TestStopsAtTheFailingStep(t *testing.T) {
	// each step that fails ends the run: nothing after it is called
	for _, c := range []struct {
		name  string
		rules func(w *kitworld.World)
		env   []string
		rc    int
		never string
	}{
		{"dirty tree", func(w *kitworld.World) { w.Rule("git", "*status --porcelain*", 0, "dirty.txt", 0, "") }, nil, 24, "git fetch"},
		{"fetch", func(w *kitworld.World) { w.Rule("git", "*fetch*", 1, "", 0, "") }, nil, 21, "git merge-base"},
		{"rdd error", func(w *kitworld.World) {}, []string{"STUB_START_RC=7"}, 14, "RUNALL"},
		{"rdd consent", func(w *kitworld.World) {}, []string{"STUB_START_RC=15"}, 15, "RUNALL"},
		{"drive not approved", func(w *kitworld.World) {}, []string{"STUB_DRIVE_RC=9"}, 13, "RUNALL"},
		{"ci", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 1, "pr-checks-fail.txt", 0, "") }, nil, 17, "merge-gate.sh"},
	} {
		w := kitworld.New(t)
		c.rules(w)
		happy(w)
		r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, c.env...)
		if r.rc != c.rc {
			t.Errorf("%s: rc %d, want %d: %+v", c.name, r.rc, c.rc, r)
		}
		// the Go side runs `git -C <worktree> ...`: compare without the -C
		if calls := gitDirFlag.ReplaceAllString(w.Calls(), "git "); count(calls, c.never) != 0 {
			t.Errorf("%s: %q was called: %q", c.name, c.never, calls)
		}
	}
}

func TestDirtyTreeStopsBeforeAnyFetch(t *testing.T) {
	w := kitworld.New(t)
	w.Rule("git", "*status --porcelain*", 0, "dirty.txt", 0, "")
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"})
	if r.rc != 24 || r.out != "kit-pr-pipeline: dirty-tree: #7: tracked files have uncommitted changes; commit or stash them\n" || strings.Contains(w.Calls(), "fetch") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}

func TestFailingGitStatusIsATypedErrorNotACleanTree(t *testing.T) {
	w := kitworld.New(t)
	w.Rule("git", "*status --porcelain*", 128, "", 0, "")
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"})
	want := "kit-pr-pipeline: restack-error: #7: git status failed (rc=128); the tree could not be judged clean\n"
	if r.rc != 25 || r.out != want || strings.Contains(w.Calls(), "fetch") || strings.Contains(w.Calls(), "push") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}

func TestPython3IsNoLongerADependency(t *testing.T) {
	w := kitworld.New(t)
	w.Drop("python3")
	happy(w)
	if r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}); r.rc != 0 {
		t.Errorf("%+v", r)
	}
}

func TestDegradedDependencies(t *testing.T) {
	for _, c := range []struct {
		drop   string
		args   []string
		rc     int
		wanted string
	}{
		{"gentle-ai", nil, 3, "kit-pr-pipeline: degraded: missing runtime dependency: gentle-ai\n"},
		{"flock", nil, 3, "kit-pr-pipeline: degraded: missing runtime dependency: flock\n"},
		{"flock", []string{"--no-gate"}, 0, ""},
	} {
		w := kitworld.New(t)
		w.Drop(c.drop)
		happy(w)
		args := append([]string{"--state-dir", w.Dir + "/st"}, c.args...)
		r := goRun(t, w, append(args, w.Wt, "7", "b"))
		if r.rc != c.rc || (c.wanted != "" && r.out != c.wanted) || (c.rc == 3 && r.err != "DEGRADED: "+strings.TrimPrefix(strings.TrimSuffix(c.wanted, "\n"), "kit-pr-pipeline: degraded: ")+"\n") {
			t.Errorf("%s %v: %+v", c.drop, c.args, r)
		}
	}
}

func TestDriveLogAndSummary(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	text := "RUN a\nLAUNCH b\nl1\nl2\nl3\nl4\nl5\nl6\nl7\n" + strings.Repeat("é", 305) + "\n"
	_ = os.WriteFile(w.Dir+"/drive.txt", []byte(text), 0o644)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", w.Wt, "7", "b"}, "STUB_DRIVE_OUT="+w.Dir+"/drive.txt")
	if r.rc != 0 {
		t.Fatalf("%+v", r)
	}
	// the whole drive output is in the log; the console gets the last 6 non-progress lines, cut to 300 characters
	if b, _ := os.ReadFile(w.Dir + "/st/rdd-drive-7.log"); string(b) != text {
		t.Errorf("log = %q", b)
	}
	want := "l3\nl4\nl5\nl6\nl7\n" + strings.Repeat("é", 300) + "\n"
	if !strings.Contains(r.out, want) || strings.Contains(r.out, "RUN a") || strings.Contains(r.out, "l2\n") {
		t.Errorf("out = %q", r.out)
	}
}

func TestTailLinesAndCut(t *testing.T) {
	if got := tailLines(""); len(got) != 0 {
		t.Errorf("empty log: %q", got)
	}
	if got := tailLines("RUN x\nLAUNCH y\n"); len(got) != 0 {
		t.Errorf("only progress: %q", got)
	}
	if got := strings.Join(tailLines("a\nRUNNING-not-noise? no: RUN\nb\n"), "|"); got != "a|b" {
		t.Errorf("progress filtered by prefix: %q", got)
	}
	if got := strings.Join(tailLines("1\n2\n3\n4\n5\n6\n"), ""); got != "123456" {
		t.Errorf("exactly six kept: %q", got)
	}
	if got := strings.Join(tailLines("1\n2\n3\n4\n5\n6\n7"), ""); got != "234567" {
		t.Errorf("no trailing newline, last six: %q", got)
	}
	if cut("abc", 3) != "abc" || cut("abcd", 3) != "abc" || cut("éé", 1) != "é" {
		t.Errorf("cut")
	}
}

func TestGateLockTimeoutAndStateInsideWorktree(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Wt + "/s", w.Wt, "7", "b"})
	if r.rc != 2 || !strings.HasPrefix(r.out, "kit-pr-pipeline: usage: --state-dir "+w.Wt+"/s is inside the worktree") || w.Calls() != "" {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
	if lockTimeout(func(string) string { return "" }) != "14400" || lockTimeout(func(string) string { return "5" }) != "5" {
		t.Errorf("lockTimeout")
	}
}

func TestSizeCheckGetsItsEnvironment(t *testing.T) {
	w := kitworld.New(t)
	happy(w)
	r := goRun(t, w, []string{"--state-dir", w.Dir + "/st", "--size-check", `echo "SIZE $KIT_PR $KIT_WORKTREE $PWD" >> "$SHIM_STATE/calls.log"`, w.Wt, "7", "b"})
	if r.rc != 0 || !strings.Contains(w.Calls(), "SIZE 7 "+w.Wt+" "+w.Wt+"\n") {
		t.Errorf("%+v calls=%q", r, w.Calls())
	}
}
