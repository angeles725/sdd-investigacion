package stage

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The tests of this file pin what the port does DIFFERENTLY from the frozen script (the defects it fixes, see
// tool-registry.d/stage-retro.md) and the seams the differential cannot reach. A test that observes git through
// a wrapper first asserts that the wrapper is the one in use (the log is not empty).

// installGit puts a logging git wrapper first on the box PATH: every call is logged, tab separated, one per line,
// to <root>/git.log, and `script` (bash, may be empty) can refuse or stall a call before the real git runs. It is
// written before the run and no test that uses it is parallel (ETXTBSY).
func (f *fx) installGit(script string) {
	f.t.Helper()
	real, err := exec.LookPath("git")
	if err != nil {
		f.t.Fatalf("the git wrapper needs git on the test host: %v", err)
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		f.t.Fatalf("the git wrapper needs bash on the test host: %v", err)
	}
	bin := filepath.Join(f.root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		f.t.Fatal(err)
	}
	body := "#!" + bash + "\nprintf '%s\\t' \"$@\" >> '" + f.root + "/git.log'\nprintf '\\n' >> '" + f.root + "/git.log'\n" + script + "\nexec '" + real + "' \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "git"), []byte(body), 0o755); err != nil {
		f.t.Fatal(err)
	}
	f.setEnv("PATH", bin+":"+os.Getenv("PATH"))
}

func (f *fx) setEnv(key, value string) {
	f.t.Helper()
	for i, kv := range f.env {
		if strings.HasPrefix(kv, key+"=") {
			f.env[i] = key + "=" + value
			return
		}
	}
	f.env = append(f.env, key+"="+value)
}

// gitCalls is the logged calls, each as its space-joined argv.
func (f *fx) gitCalls() []string {
	f.t.Helper()
	data, err := os.ReadFile(filepath.Join(f.root, "git.log"))
	if err != nil {
		return nil
	}
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		if l != "" {
			out = append(out, strings.Join(strings.Split(strings.TrimSuffix(l, "\t"), "\t"), " "))
		}
	}
	return out
}

// requireWrapperUsed fails unless the wrapper saw at least one git call: a wrapper that is not first on the PATH
// would make every "git was not called" assertion pass vacuously.
func (f *fx) requireWrapperUsed() {
	f.t.Helper()
	if len(f.gitCalls()) == 0 {
		f.t.Fatal("the git wrapper saw no call: it is not the git the command ran")
	}
}

// verbs are the git verbs of the logged calls (the -C pair skipped).
func (f *fx) verbs() []string {
	var out []string
	for _, c := range f.gitCalls() {
		args := strings.Fields(c)
		for i := 0; i < len(args); i++ {
			if args[i] == "-C" {
				i++
				continue
			}
			out = append(out, args[i])
			break
		}
	}
	return out
}

func (f *fx) called(sub string) bool {
	for _, c := range f.gitCalls() {
		if strings.Contains(c, sub) {
			return true
		}
	}
	return false
}

// run executes the command on the box with the retro of the case, optionally through Run with a mutated Options.
func (f *fx) run(args []string, mut func(*Options)) result {
	f.t.Helper()
	rc, so, se := f.runRaw(args, mut)
	return f.collect(rc, so, se)
}

// runRaw is run without the state snapshot, for the tests whose box has no usable git left to snapshot with.
func (f *fx) runRaw(args []string, mut func(*Options)) (int, string, string) {
	f.t.Helper()
	var so, se bytes.Buffer
	s := f.stdio(f.repo, &so, &se)
	o := Options{Args: args, KitRoot: f.repo, Cwd: f.repo, Getenv: s.Env, Environ: s.Environ(), Out: &so, Err: &se}
	if mut != nil {
		mut(&o)
	}
	return Run(o), so.String(), se.String()
}

func (f *fx) retroArg() []string { return []string{f.abs("targetA/retros/r1.md")} }

func box(t *testing.T, setup func(*testing.T, *fx)) *fx { return mkBox(t, dcase{setup: setup}) }

// refsOf is the heads of the box, to prove that no other ref moved.
func (f *fx) heads() string {
	return f.git(f.repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads")
}

func contains(t *testing.T, what, got string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Errorf("%s lacks %q:\n%s", what, w, got)
		}
	}
}

// D1: the script ran `git checkout -q main` first, whatever the checkout was on, and exit 4 when it failed (main
// held by another worktree). The port starts from where it is, creates the branch from origin/main, and never
// checks out main.
func TestStartsFromAnotherBranchWithoutCheckingOutMain(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) {
		f.retro("targetA", "r1.md", retroBody(mPending))
		f.git(f.repo, "checkout", "-q", "-b", "feat/x")
	})
	f.installGit("")
	mainBefore, featBefore := f.git(f.repo, "rev-parse", "main"), f.git(f.repo, "rev-parse", "feat/x")
	r := f.run(f.retroArg(), nil)
	f.requireWrapperUsed()
	if r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	if f.called("checkout -q main") {
		t.Errorf("the port checked out main: %v", f.gitCalls())
	}
	if got := f.git(f.repo, "symbolic-ref", "--short", "HEAD"); got != "retro/targetA-r1" {
		t.Errorf("HEAD %q, want the new branch", got)
	}
	if got := f.git(f.repo, "rev-parse", "retro/targetA-r1"); got != f.git(f.repo, "rev-parse", "origin/main") {
		t.Errorf("the branch is at %s, not at origin/main", got)
	}
	if f.git(f.repo, "rev-parse", "main") != mainBefore || f.git(f.repo, "rev-parse", "feat/x") != featBefore {
		t.Error("main or the starting branch moved")
	}
	if got := f.git(f.repo, "for-each-ref", "--format=%(refname)", "refs/heads"); got != "refs/heads/feat/x\nrefs/heads/main\nrefs/heads/retro/targetA-r1" {
		t.Errorf("heads after the run:\n%s", got)
	}
	if got := f.git(f.repo, "status", "--porcelain"); got != "" {
		t.Errorf("worktree or index not clean after the run: %q", got)
	}
	if out, err := f.gitRaw(f.repo, "rev-parse", "--abbrev-ref", "retro/targetA-r1@{upstream}"); err == nil {
		t.Errorf("the branch tracks %q: origin/main must never become its upstream", strings.TrimSpace(out))
	}
}

func TestMainHeldByAnotherWorktreeDoesNotBlockStaging(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) {
		f.retro("targetA", "r1.md", retroBody(mPending))
		f.git(f.repo, "checkout", "-q", "-b", "feat/x")
		f.git(f.repo, "worktree", "add", "-q", filepath.Join(f.root, "main-wt"), "main")
	})
	r := f.run(f.retroArg(), nil)
	if r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	if !strings.Contains(r.State, "HEAD refs/heads/retro/targetA-r1") {
		t.Errorf("state:\n%s", r.State)
	}
}

func TestNoHelperFilesAreNeeded(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) {
		f.git(f.repo, "rm", "-rq", "research-sdd/toolbelt/lib")
		f.retro("targetA", "r1.md", retroBody(mPending))
	})
	if r := f.run(f.retroArg(), nil); r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
}

// D2: a name git refuses is found before the fetch and before anything changes.
func TestInvalidBranchNameRefusedBeforeAnyChange(t *testing.T) {
	for file, slug := range map[string]string{"a..b.md": "a..b", "x.lock.md": "x.lock", "trail..md": "trail."} {
		t.Run(file, func(t *testing.T) {
			f := box(t, func(t *testing.T, f *fx) { f.retro("targetA", file, retroBody(mPending)) })
			f.installGit("")
			before := f.state()
			r := f.run([]string{f.abs("targetA/retros/" + file)}, nil)
			f.requireWrapperUsed()
			if r.RC != 5 || r.Stdout != "" {
				t.Fatalf("rc %d out %q: %s", r.RC, r.Stdout, r.Stderr)
			}
			if !strings.HasSuffix(r.Stderr, "stage-retro: 'retro/targetA-"+slug+"' is not a valid branch name (target 'targetA', file '"+file+"') — nothing was changed; rename the retro file or register a plain target name.\n") {
				t.Errorf("stderr:\n%s", r.Stderr)
			}
			if f.called("fetch") || f.called("checkout") {
				t.Errorf("git changed state before the refusal: %v", f.gitCalls())
			}
			if r.State != before {
				t.Errorf("state changed:\nbefore %s\nafter  %s", before, r.State)
			}
		})
	}
	for _, file := range []string{".md", "dot.md.md"} {
		f := box(t, func(t *testing.T, f *fx) { f.retro("targetA", file, retroBody(mPending)) })
		if r := f.run([]string{f.abs("targetA/retros/" + file)}, nil); r.RC != 0 {
			t.Errorf("%s: a valid name was refused (rc %d): %s", file, r.RC, r.Stderr)
		}
	}
}

// D3: a file name with nothing the slug keeps used to share one branch with every other such file.
func TestNonASCIIFileNamesGetDistinctStableBranches(t *testing.T) {
	a, b := slugOf("日本.md"), slugOf("中文.md")
	if a == b || !strings.HasPrefix(a, "retro-") || len(a) != len("retro-")+8 || a != slugOf("dir/日本.md") {
		t.Fatalf("slugs %q %q", a, b)
	}
	for _, file := range []string{"日本.md", "中文.md"} {
		f := box(t, func(t *testing.T, f *fx) { f.retro("targetA", file, retroBody(mPending)) })
		r := f.run([]string{f.abs("targetA/retros/" + file)}, nil)
		if r.RC != 0 {
			t.Fatalf("%s: rc %d: %s", file, r.RC, r.Stderr)
		}
		contains(t, "stdout", r.Stdout, "   branch: retro/targetA-"+slugOf(file)+"\n")
	}
}

// D4: the script ignored every word after the retro but a second-position --force.
func TestUnknownArgumentRefusedBeforeAnyGitCall(t *testing.T) {
	f := box(t, simple(mPending))
	f.installGit("")
	before := f.state()
	n := len(f.gitCalls())
	for _, extra := range [][]string{{"--forse"}, {"--force", "extra"}, {"x", "--force"}} {
		r := f.run(append(f.retroArg(), extra...), nil)
		bad := extra[0]
		if extra[0] == "--force" {
			bad = extra[1]
		}
		if r.RC != 1 || r.Stdout != "" || r.Stderr != "stage-retro: unknown argument '"+bad+"' (the only option after the retro is --force)\n" {
			t.Errorf("%v: rc %d out %q err %q", extra, r.RC, r.Stdout, r.Stderr)
		}
		if r.State != before {
			t.Errorf("%v changed the repo", extra)
		}
	}
	if len(f.gitCalls()) != n {
		t.Errorf("git ran for a refused argument: %v", f.gitCalls()[n:])
	}
}

func TestForceReStagesAnAppliedRetroAndSaysSo(t *testing.T) {
	f := box(t, simple(mApplied))
	r := f.run(append(f.retroArg(), "--force"), nil)
	if r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stderr", r.Stderr, "This retro is already 'applied' — re-staging because --force was given.\n")
	if strings.Contains(r.Stderr, "Use --force") {
		t.Errorf("the refusal advice is printed although --force was given:\n%s", r.Stderr)
	}
	if !strings.Contains(r.State, "HEAD refs/heads/retro/targetA-r1") {
		t.Errorf("not staged:\n%s", r.State)
	}
}

// D5: a section that runs to the end of the file lost its last line to the script's `sed '$d'`.
func TestSectionAtEndOfFileKeepsItsLastLine(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) {
		f.retro("targetA", "r1.md", mPending+"\n# retro\n\n## Proposed kit deltas\n\n| 1 | first | r |\n| 2 | LAST-ROW | r |\n")
	})
	r := f.run(f.retroArg(), nil)
	if r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stdout", r.Stdout, "| 2 | LAST-ROW | r |\n")
}

func TestSection(t *testing.T) {
	raw := strings.Split("a\n## Proposed kit deltas x\nb\n\n## Other\nc\n## Proposed kit deltas\nd", "\n")
	got, found := section(raw, reDeltas)
	// two ranges: the first is closed by `## Other` (dropped only when it is the LAST range's closer), the
	// second runs to the end of the file (nothing dropped)
	if !found || strings.Join(got, "|") != "## Proposed kit deltas x|b||## Other|## Proposed kit deltas|d" {
		t.Errorf("found %v: %q", found, got)
	}
	got, _ = section(strings.Split("## Proposed kit deltas\nb\n## C\nz", "\n"), reDeltas)
	if strings.Join(got, "|") != "## Proposed kit deltas|b" {
		t.Errorf("closer kept: %q", got)
	}
	if got, found := section([]string{"x", "##Proposed kit deltas"}, reDeltas); found || got != nil {
		t.Errorf("a heading without the space matched: %q", got)
	}
	if got, _ := section([]string{"## Proposed kit deltas", "##", "b", "## "}, reDeltas); strings.Join(got, "|") != "## Proposed kit deltas|##|b" {
		t.Errorf("`##` alone closed the range, or `## ` did not: %q", got)
	}
	if joinLines(nil) != "" || joinLines([]string{"a"}) != "a\n" {
		t.Error("joinLines")
	}
}

// D6: a retro with no deltas section printed nothing, silently.
func TestMissingDeltasSectionWarns(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) { f.retro("targetA", "r1.md", mPending+"\n# retro\n\nnothing here\n") })
	r := f.run(f.retroArg(), nil)
	if r.RC != 0 {
		t.Fatalf("rc %d", r.RC)
	}
	contains(t, "stderr", r.Stderr, "WARN: no '## Proposed kit deltas' section found in "+"@BOX@/repo/targetA/retros/r1.md — there are no deltas to print.\n")
}

// D9: a kit root that is not a repository, or no git at all, was read as "clean" and failed later.
func TestKitRootThatIsNotARepositoryIsRefused(t *testing.T) {
	f := box(t, simple(mPending))
	f.setEnv("GIT_CEILING_DIRECTORIES", f.root)
	if err := os.RemoveAll(filepath.Join(f.repo, ".git")); err != nil {
		t.Fatal(err)
	}
	rc, out, errOut := f.runRaw(f.retroArg(), nil)
	if rc != 4 || out != "" {
		t.Fatalf("rc %d out %q", rc, out)
	}
	contains(t, "stderr", errOut, "fatal: not a git repository", "degraded: git could not read the state of the kit repo in "+f.repo+" (git status --porcelain: exit 128: fatal: not a git repository")
}

func TestNoGitOnThePathIsATypedDegradedExit(t *testing.T) {
	f := box(t, simple(mPending))
	empty := filepath.Join(f.root, "empty")
	if err := os.MkdirAll(empty, 0o755); err != nil {
		t.Fatal(err)
	}
	f.setEnv("PATH", empty)
	rc, out, errOut := f.runRaw(f.retroArg(), nil)
	if rc != 4 || out != "" || !strings.HasSuffix(errOut, "degraded: git not found on PATH — cannot read the state of the kit repo; nothing was changed.\n") {
		t.Errorf("rc %d out %q err %q", rc, out, errOut)
	}
}

// D10: git fetch is bounded.
func TestFetchThatHangsTimesOutAsADegradedExit(t *testing.T) {
	f := box(t, simple(mPending))
	f.installGit("case \" $* \" in *\" fetch \"*) while :; do :; done ;; esac")
	headsBefore := f.heads()
	var so, se bytes.Buffer
	s := f.stdio(f.repo, &so, &se)
	start := time.Now()
	rc := Run(Options{Args: f.retroArg(), KitRoot: f.repo, Cwd: f.repo, Getenv: s.Env, Environ: s.Environ(), Out: &so, Err: &se, FetchTimeout: 300 * time.Millisecond})
	f.requireWrapperUsed()
	if rc != 6 {
		t.Fatalf("rc %d: %s", rc, se.String())
	}
	if time.Since(start) > 20*time.Second {
		t.Errorf("took %v", time.Since(start))
	}
	contains(t, "stderr", se.String(), "git: timed out after 300ms: git fetch -q origin\n", "degraded: git fetch origin failed — cannot verify remote state; refusing to branch from a possibly stale base.\n")
	if f.heads() != headsBefore {
		t.Error("a ref changed")
	}
}

// D13: a single quote in the label or the file name ended the quoting of the suggested commands.
func TestSingleQuotesInTheSuggestedCommandsAreEscaped(t *testing.T) {
	f := box(t, func(t *testing.T, f *fx) {
		f.targets("o'brien", "targetA")
		f.retro("targetA", "it's.md", retroBody(mPending))
	})
	r := f.run([]string{f.abs("targetA/retros/it's.md")}, nil)
	if r.RC != 0 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stdout", r.Stdout,
		`-m 'feat(kit): apply retro deltas from o'\''brien (it-s)' -m 'Retro: o'\''brien/retros/it'\''s.md@<sha>'`,
		`--title 'retro: o'\''brien it-s'`)
	if q := shellQuote("it's"); q != `'it'\''s'` {
		t.Errorf("shellQuote %s", q)
	}
}

// D14: an unreadable retro was staged (a branch created) and refused only after the checkout.
func TestUnreadableRetroIsRefusedBeforeAnyGitCall(t *testing.T) {
	f := box(t, simple(mPending))
	f.installGit("")
	n := len(f.gitCalls())
	r := f.run(f.retroArg(), func(o *Options) {
		o.Read = func(string) (*retrogrammar.Doc, error) { return nil, retrogrammar.ErrUnreadable }
	})
	if r.RC != 1 || r.Stdout != "" || r.Stderr != "degraded: retro not readable: @BOX@/repo/targetA/retros/r1.md\n" {
		t.Errorf("rc %d out %q err %q", r.RC, r.Stdout, r.Stderr)
	}
	if len(f.gitCalls()) != n {
		t.Errorf("git ran: %v", f.gitCalls()[n:])
	}
}

// exit 8: the retro vanishes on the branch; the checkout goes back where it was.
func staleBranchBox(t *testing.T, mut func(*fx)) *fx {
	return box(t, func(t *testing.T, f *fx) {
		f.git(f.repo, "branch", "-q", "retro/targetA-r1", "origin/main")
		f.retro("targetA", "r1.md", retroBody(mPending))
		if mut != nil {
			mut(f)
		}
	})
}

func TestExit8SwitchBackFailsIsReportedTruthfully(t *testing.T) {
	f := staleBranchBox(t, nil)
	f.installGit("case \" $* \" in *\" checkout -q main \"*) echo 'shim: forced checkout failure' >&2; exit 1 ;; esac")
	r := f.run(f.retroArg(), nil)
	f.requireWrapperUsed()
	if r.RC != 8 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	if !f.called("checkout -q main") {
		t.Fatalf("the switch-back never ran through the wrapper: %v", f.gitCalls())
	}
	if strings.Contains(r.Stderr, "Switched back") {
		t.Errorf("claims a switch that did not happen:\n%s", r.Stderr)
	}
	contains(t, "stderr", r.Stderr,
		"Could NOT switch back to main (the checkout failed) — the repo is still on retro/targetA-r1.\nIf retro/targetA-r1 is a stale leftover branch that predates this retro,\n")
}

func TestExit8ReturnsToTheStartingBranchAndTheBranchIsDeletable(t *testing.T) {
	f := staleBranchBox(t, nil)
	r := f.run(f.retroArg(), nil)
	if r.RC != 8 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stderr", r.Stderr, "Switched back to main. If retro/targetA-r1 is a stale leftover branch that predates this retro,\ndelete it: git -C \""+"@BOX@/repo"+"\" checkout main && git -C \"@BOX@/repo\" branch -D retro/targetA-r1\n")
	f.git(f.repo, "branch", "-D", "retro/targetA-r1") // the plain remediation works with no extra checkout
}

func TestExit8FromAnotherBranchReturnsThereNotToMain(t *testing.T) {
	f := staleBranchBox(t, func(f *fx) { f.git(f.repo, "checkout", "-q", "-b", "feat/x") })
	r := f.run(f.retroArg(), nil)
	if r.RC != 8 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stderr", r.Stderr, "Switched back to feat/x.", "checkout feat/x && git")
	if got := f.git(f.repo, "symbolic-ref", "--short", "HEAD"); got != "feat/x" {
		t.Errorf("HEAD %q", got)
	}
}

func TestExit8FromADetachedHeadReturnsToTheCommit(t *testing.T) {
	f := staleBranchBox(t, func(f *fx) { f.git(f.repo, "checkout", "-q", "--detach", "main") })
	sha := f.git(f.repo, "rev-parse", "HEAD")
	r := f.run(f.retroArg(), nil)
	if r.RC != 8 {
		t.Fatalf("rc %d: %s", r.RC, r.Stderr)
	}
	contains(t, "stderr", r.Stderr, "Switched back to "+sha+".", "checkout --detach "+sha+" && git")
	if got := f.git(f.repo, "rev-parse", "HEAD"); got != sha {
		t.Errorf("HEAD %s, want %s", got, sha)
	}
	if _, err := f.gitRaw(f.repo, "symbolic-ref", "-q", "HEAD"); err == nil {
		t.Error("HEAD is on a branch, want detached")
	}
}

// RunCommand: the toolbelt may be relative, and without one the kit resolution runs.
func TestRelativeToolbeltResolvesAgainstTheWorkingDirectory(t *testing.T) {
	f := box(t, simple(mPending))
	var so, se bytes.Buffer
	rc := RunCommand([]string{"--toolbelt", "research-sdd/toolbelt", f.abs("targetA/retros/r1.md")}, f.stdio(f.repo, &so, &se))
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, se.String())
	}
	contains(t, "stdout", f.normalize(so.String()), "git -C \"@BOX@/repo\" add -A")
}

func TestNoToolbeltAndNoKitIsATypedFailure(t *testing.T) {
	f := box(t, simple(mPending))
	f.setEnv("HOME", filepath.Join(f.root, "nohome"))
	f.setEnv("RESEARCH_SDD_KIT", "")
	var so, se bytes.Buffer
	rc := RunCommand(f.retroArg(), f.stdio(f.repo, &so, &se))
	if rc != 1 || so.Len() != 0 || se.String() != "stage-retro: cannot find the kit toolbelt: research-sdd kit not found (set RESEARCH_SDD_KIT)\n" {
		t.Errorf("rc %d out %q err %q", rc, so.String(), se.String())
	}
}

func TestInvalidResearchSDDKitIsWarned(t *testing.T) {
	f := box(t, simple(mPending))
	f.setEnv("HOME", filepath.Join(f.root, "nohome"))
	f.setEnv("RESEARCH_SDD_KIT", filepath.Join(f.root, "not-a-kit"))
	var so, se bytes.Buffer
	if rc := RunCommand(f.retroArg(), f.stdio(f.repo, &so, &se)); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	contains(t, "stderr", f.normalize(se.String()), "kit-run: DEGRADED: RESEARCH_SDD_KIT=@BOX@/not-a-kit invalid (no toolbelt/ directory); trying the launcher files and the default checkout\n")
}

func TestResolvedKitToolbeltStagesThroughTheKit(t *testing.T) {
	f := box(t, simple(mPending))
	f.setEnv("RESEARCH_SDD_KIT", f.abs("research-sdd"))
	var so, se bytes.Buffer
	if rc := RunCommand(f.retroArg(), f.stdio(f.repo, &so, &se)); rc != 0 {
		t.Fatalf("rc %d: %s", rc, se.String())
	}
	if got := f.git(f.repo, "symbolic-ref", "--short", "HEAD"); got != "retro/targetA-r1" {
		t.Errorf("HEAD %q", got)
	}
}
