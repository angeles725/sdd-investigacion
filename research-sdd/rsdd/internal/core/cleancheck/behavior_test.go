package cleancheck

import (
	"io/fs"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The typed result: every absent input and degraded check is a value, not only text.
func TestTypedStatesAreValues(t *testing.T) {
	w := newWorld(t)
	w.git("branch", "-m", "trunk")
	r := w.check(func(o *Options) { o.Scratchpad = w.root + "/nope"; o.Evidence = w.root + "/noev" })
	want := []Absent{{AbsentKeepList, w.repo + "/.research-sdd/keep.txt"}, {AbsentScratchpad, w.root + "/nope"}, {AbsentBase, ""}, {AbsentEvidence, w.root + "/noev"}}
	if !reflect.DeepEqual(r.Absent, want) {
		t.Errorf("Absent = %+v, want %+v", r.Absent, want)
	}
	if r.Verdict != Clean || r.Exit != 0 || r.Findings != 0 || r.Degraded != nil || !strings.HasPrefix(r.Summary, "CLEAN-CHECK: clean (") {
		t.Errorf("%+v", r)
	}
	if r.Lines[len(r.Lines)-1].Text != r.Summary || r.Lines[len(r.Lines)-1].Stream != Out {
		t.Errorf("the summary is the last stdout line: %+v", r.Lines)
	}
}

func TestDegradedStatesAreValues(t *testing.T) {
	w := newWorld(t)
	w.stubRules(rule{match: "worktree list", errText: "fatal: boom\\n", rc: 128}, rule{match: "for-each-ref", errText: "fatal: boom2\\n", rc: 128})
	w.git("branch", "m1")
	r := w.check()
	if r.Verdict != Degraded || r.Exit != 3 || !reflect.DeepEqual(r.Degraded, []DegradedKind{DegradedWorktree, DegradedBranch}) {
		t.Errorf("%s %+v", w.dump(r), r.Degraded)
	}
	if !strings.Contains(r.Summary, "degraded: worktree scan failed; branch scan failed)") {
		t.Errorf("both reasons are named: %s", r.Summary)
	}
}

func TestGitMissingIsDegradedWithNoSummary(t *testing.T) {
	w := newWorld(t)
	w.mkdir(w.root + "/empty")
	r := w.check(func(o *Options) { o.Env = []string{"PATH=" + w.root + "/empty"} })
	if r.Verdict != Degraded || r.Exit != 3 || r.Summary != "" || !reflect.DeepEqual(r.Degraded, []DegradedKind{DegradedGit}) {
		t.Errorf("%+v", r)
	}
	if r.Stdout() != "" || r.Stderr() != "clean-check: DEGRADED: git not found on PATH; nothing was measured\n" {
		t.Errorf("%q %q", r.Stdout(), r.Stderr())
	}
}

// Only git is a dependency now: the script also needed find, sort, date, id and stat on PATH.
func TestOnlyGitIsADependency(t *testing.T) {
	w := newWorld(t)
	w.write("stray.txt", "x")
	real, err := exec.LookPath("git")
	if err != nil {
		t.Fatal(err)
	}
	w.mkdir(w.root + "/only")
	if err := os.Symlink(real, w.root+"/only/git"); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Env = append(append([]string(nil), o.Env...), "PATH="+w.root+"/only") })
	if r.Exit != 1 || !has(r, "GARBAGE untracked stray.txt") {
		t.Errorf("%s", w.dump(r))
	}
}

// A refused run never reads as clean and has no summary line.
func TestRefusedRunsHaveNoSummary(t *testing.T) {
	w := newWorld(t)
	for name, adjust := range map[string]func(*Options){
		"target":  func(o *Options) { o.Target = w.root + "/nope" },
		"tmp":     func(o *Options) { o.Tmp = w.root + "/nope" },
		"uid":     func(o *Options) { o.UID = "x" },
		"base":    func(o *Options) { o.Base = "nope" },
		"nottree": func(o *Options) { o.Target = w.tmp },
	} {
		r := w.check(adjust)
		if r.Verdict != Refused || r.Exit != 2 || r.Summary != "" || r.Stdout() != "" || !strings.HasPrefix(r.Stderr(), "clean-check: ERROR: ") {
			t.Errorf("%s: %s", name, w.dump(r))
		}
	}
}

func TestInputMessages(t *testing.T) {
	w := newWorld(t)
	for name, c := range map[string]struct {
		adjust func(*Options)
		want   string
	}{
		"target":   {func(o *Options) { o.Target = w.root + "/nope" }, "clean-check: ERROR: target not found: " + w.root + "/nope\n"},
		"tmp":      {func(o *Options) { o.Tmp = w.root + "/nope" }, "clean-check: ERROR: tmp dir not found: " + w.root + "/nope\n"},
		"tmpslash": {func(o *Options) { o.Tmp = w.root + "/nope/" }, "clean-check: ERROR: tmp dir not found: " + w.root + "/nope\n"},
		"uid":      {func(o *Options) { o.UID = "12x" }, "clean-check: ERROR: cannot determine the owner uid ('12x')\n"},
		"uidneg":   {func(o *Options) { o.UID = "-1" }, "clean-check: ERROR: cannot determine the owner uid ('-1')\n"},
		"base":     {func(o *Options) { o.Base = "nope" }, "clean-check: ERROR: --base ref not found or not a commit: nope\n"},
		"nottree":  {func(o *Options) { o.Target = w.tmp }, "clean-check: ERROR: git rev-parse failed for target " + w.tmp + ": fatal: not a git repository (or any of the parent directories): .git\n"},
		"gitdir":   {func(o *Options) { o.Target = w.repo + "/.git" }, "clean-check: ERROR: target is not inside a git work tree: " + w.repo + "/.git\n"},
	} {
		if got := w.check(c.adjust).Stderr(); got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", name, got, c.want)
		}
	}
}

func TestOwnerUIDDefaultsToTheCurrentUser(t *testing.T) {
	w := newWorld(t)
	ageTmp(w, "tmp.old", 48, false)
	if r := w.check(func(o *Options) { o.Self = func() int { return os.Getuid() } }); !has(r, "GARBAGE stale-tmp "+w.tmp+"/tmp.old age=48h") {
		t.Error(w.dump(r))
	}
	if r := w.check(func(o *Options) { o.Self = func() int { return os.Getuid() + 1 } }); r.Findings != 0 {
		t.Error("another owner's entries are never reported:\n" + w.dump(r))
	}
	if r := w.check(func(o *Options) { o.UID = "0"; o.Self = func() int { return os.Getuid() } }); os.Getuid() != 0 && r.Findings != 0 {
		t.Error("an explicit uid wins over the current user:\n" + w.dump(r))
	}
	if r := w.check(); !has(r, "GARBAGE stale-tmp "+w.tmp+"/tmp.old age=48h") {
		t.Error("the process uid is the default:\n" + w.dump(r))
	}
}

// The clock is Options.Now: an age is measured against it, never against the machine's.
func TestAgesFollowTheInjectedClock(t *testing.T) {
	w := newWorld(t)
	ageTmp(w, "tmp.old", 48, false)
	w.writeAt(w.root+"/ev/backup-x/f", "x")
	w.ago(24*30, w.root+"/ev/backup-x")
	later := func(h int) func(*Options) {
		return func(o *Options) {
			o.Now = func() time.Time { return time.Now().Add(time.Duration(h) * time.Hour) }
			o.Evidence = w.root + "/ev"
		}
	}
	r := w.check(later(100))
	if !has(r, "GARBAGE stale-tmp "+w.tmp+"/tmp.old age=148h") || !has(r, "WARN stale-backup "+w.root+"/ev/backup-x age=34d retention=14d") {
		t.Error(w.dump(r))
	}
	r = w.check(later(-480))
	if r.Findings != 0 || strings.Contains(r.Merged(), "stale-backup") {
		t.Errorf("a clock 20 days in the past makes a 30-day-old backup young:\n%s", w.dump(r))
	}
}

func TestAnEntryThatVanishesIsUnknownAge(t *testing.T) {
	w := newWorld(t)
	ageTmp(w, "tmp.old", 48, false)
	w.mkdir(w.root + "/ev/backup-x")
	w.ago(24*30, w.root+"/ev/backup-x")
	r := newRun(w.opts())
	r.lstat = func(p string) (fs.FileInfo, error) {
		if strings.HasSuffix(p, "tmp.old") || strings.HasSuffix(p, "backup-x") {
			return nil, fs.ErrNotExist
		}
		return os.Lstat(p)
	}
	if got := r.ageIn(w.tmp+"/tmp.old", 3600, "h"); got != "unknown" {
		t.Errorf("a vanished entry has an unknown age: %q", got)
	}
	r.lstat = os.Lstat
	if got := r.ageIn(w.tmp+"/tmp.old", 3600, "h"); got != "unknown" && !strings.HasSuffix(got, "h") {
		t.Errorf("%q", got)
	}
	r.now = time.Now()
	if got := r.ageIn(w.tmp+"/tmp.old", 3600, "h"); got != "48h" {
		t.Errorf("%q", got)
	}
	if got := r.ageIn(w.root+"/ev/backup-x", 86400, "d"); got != "30d" {
		t.Errorf("%q", got)
	}
}

// S4: read-only. A run that reports everything changes nothing in the target, the tmp directory or the scratchpad.
func TestCheckNeverWritesAnything(t *testing.T) {
	w := newWorld(t)
	scratchWorld(w)
	ageTmp(w, "tmp.old", 48, false)
	w.git("branch", "m1")
	w.git("worktree", "add", "-q", w.root+"/wtx", "-b", "wtx")
	before := w.snapshot()
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Exit != 1 {
		t.Fatal(w.dump(r))
	}
	if after := w.snapshot(); after != before {
		t.Errorf("the tree changed:\n--- before\n%s\n--- after\n%s", before, after)
	}
}

// snapshot is every path below the world root with its size and mtime, .git internals included.
func (w *world) snapshot() string {
	var b strings.Builder
	err := walkErr(w.root, func(p string, fi fs.FileInfo) {
		b.WriteString(p + " " + fi.Mode().String() + " " + fi.ModTime().String() + "\n")
	})
	if err != nil {
		w.t.Fatal(err)
	}
	return b.String()
}

func walkErr(root string, f func(string, fs.FileInfo)) error {
	var walk func(string) error
	walk = func(dir string) error {
		ents, err := os.ReadDir(dir)
		if err != nil {
			return err
		}
		for _, e := range ents {
			p := dir + "/" + e.Name()
			fi, err := e.Info()
			if err != nil {
				return err
			}
			f(p, fi)
			if e.IsDir() {
				if err := walk(p); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return walk(root)
}

// git's stderr is left visible, even when git succeeds.
func TestGitDiagnosticsStayVisible(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.stubRules(rule{match: "ls-files --others --exclude-standard -z", out: "stray.txt\\0", errText: "warning: could not open directory x/: Permission denied\\n"})
	r := w.check()
	want := []Line{{Err, "warning: could not open directory x/: Permission denied"}, {Out, "GARBAGE untracked stray.txt"}}
	if !reflect.DeepEqual(r.Lines[:2], want) {
		t.Errorf("%+v", r.Lines)
	}
}

func TestSettleScratchpad(t *testing.T) {
	w := newWorld(t)
	w.mkdir(w.root + "/real")
	if err := os.Symlink(w.root+"/real", w.root+"/link"); err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]string{
		"": "", "/": "/", "//": "/", w.root + "/link": w.root + "/real", w.root + "/link/": w.root + "/real", "link": w.root + "/real",
		"nope": "nope", "nope/": "nope", "nope//": "nope/", w.root + "/real/../real": w.root + "/real",
	} {
		r := newRun(Options{Scratchpad: in, Cwd: w.root})
		r.settleScratchpad()
		if r.scratchP != want {
			t.Errorf("scratchpad %q settled to %q, want %q", in, r.scratchP, want)
		}
	}
}

func TestInScratch(t *testing.T) {
	r := &run{scratchP: "/s"}
	for p, want := range map[string]bool{"/s": true, "/s/a": true, "/s/a/b": true, "/sx": false, "/s2/a": false, "/": false, "": false, "/t/s": false} {
		if r.inScratch(p) != want {
			t.Errorf("inScratch(%q) = %v", p, !want)
		}
	}
	if (&run{}).inScratch("/s") {
		t.Error("no scratchpad configured: nothing is inside it")
	}
	if !(&run{scratchP: "/"}).inScratch("/any/thing") {
		t.Error("the root scratchpad holds everything")
	}
}

// Divergence: a script whose name holds a newline is no longer taken for a manifested one. The script's `grep -qxF`
// read the name as two patterns and matched the manifest's name on the second line.
func TestNewlineNamedScriptIsNotManifested(t *testing.T) {
	w := newWorld(t)
	keep(w, "sources/\n")
	w.write("sources/probes/b/SCRIPTS-MANIFEST.md", "| listed.sh | "+sum("x")+" |\n")
	w.writeAt(w.scratch+"/junk\nlisted.sh", "x")
	w.writeAt(w.scratch+"/listed.sh", "x")
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/junk\nlisted.sh") || has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/listed.sh") || r.Findings != 1 {
		t.Error(w.dump(r))
	}
}

// Divergence: a symlinked --evidence directory is read through (find does not follow a command-line symlink, so the
// script reported 0 scanned entries for it).
func TestSymlinkedEvidenceDirIsReadThrough(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.root+"/real/backup-old/f", "x")
	w.ago(24*30, w.root+"/real/backup-old")
	if err := os.Symlink(w.root+"/real", w.root+"/evlink"); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Evidence = w.root + "/evlink" })
	if !has(r, "WARN stale-backup "+w.root+"/evlink/backup-old age=30d retention=14d") || r.Warnings != 1 {
		t.Error(w.dump(r))
	}
}

// Divergence: the scratchpad "/" is a scratchpad (the script cut it to nothing and reported "not set").
func TestRootScratchpadIsConfigured(t *testing.T) {
	r := newRun(Options{Scratchpad: "/", Cwd: "/"})
	r.settleScratchpad()
	if r.scratchP != "/" {
		t.Errorf("%q", r.scratchP)
	}
}

func TestBlocksThatCannotBeReadRefuse(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("a permission case needs a non-root user")
	}
	w := newWorld(t)
	keep(w, "")
	w.write("docs/a.md", "x\n")
	w.writeAt(w.scratch+"/f.txt", "x")
	if err := os.Chmod(w.repo+"/docs/a.md", 0); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Exit != 2 || !has(r, "clean-check: ERROR: grep failed reading block docs/a.md") || !has(r, "grep: "+w.repo+"/docs/a.md: Permission denied") {
		t.Error(w.dump(r))
	}
}

func TestUnreadableManifestAndProbesRefuse(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("a permission case needs a non-root user")
	}
	w := newWorld(t)
	keep(w, "sources/\n")
	w.write("sources/probes/b/SCRIPTS-MANIFEST.md", "| a.sh | "+sum("a")+" |\n")
	w.writeAt(w.scratch+"/a.sh", "x")
	mf := w.repo + "/sources/probes/b/SCRIPTS-MANIFEST.md"
	if err := os.Chmod(mf, 0); err != nil {
		t.Fatal(err)
	}
	if r := w.check(func(o *Options) { o.Scratchpad = w.scratch }); r.Exit != 2 || !has(r, "clean-check: ERROR: cannot parse manifest "+mf) {
		t.Error(w.dump(r))
	}
	if err := os.Chmod(mf, 0o644); err != nil {
		t.Fatal(err)
	}
	w.write("sources/probes/locked/f", "x")
	if err := os.Chmod(w.repo+"/sources/probes/locked", 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(w.repo+"/sources/probes/locked", 0o755) })
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Exit != 2 || !has(r, "clean-check: ERROR: manifest scan failed under "+w.repo+"/sources/probes; UNMANIFESTED-SCRIPT not evaluated") ||
		!has(r, "find: '"+w.repo+"/sources/probes/locked': Permission denied") {
		t.Error(w.dump(r))
	}
}

func TestTmpDefaultsToTMPDIR(t *testing.T) {
	w := newWorld(t)
	ageTmp(w, "tmp.old", 48, false)
	r := w.check(func(o *Options) { o.Tmp = ""; o.Env = append(append([]string(nil), o.Env...), "TMPDIR="+w.tmp+"/") })
	if !has(r, "GARBAGE stale-tmp "+w.tmp+"/tmp.old age=48h") || !strings.Contains(r.Summary, "tmp.* in "+w.tmp+" older") {
		t.Error(w.dump(r))
	}
	r = w.check(func(o *Options) { o.Tmp = ""; o.Env = append(append([]string(nil), o.Env...), "TMPDIR=") })
	if !strings.Contains(r.Summary, "tmp.* in /tmp older") {
		t.Error("an empty TMPDIR is /tmp:\n" + w.dump(r))
	}
	r = w.check(func(o *Options) { o.Tmp = "/" })
	if !strings.Contains(r.Summary, "tmp.* in / older") {
		t.Error("a lone slash stays the root:\n" + w.dump(r))
	}
}

func TestTargetDefaultsToTheWorkingDirectory(t *testing.T) {
	w := newWorld(t)
	w.write("stray.txt", "x")
	r := w.check(func(o *Options) { o.Target = ""; o.Cwd = w.repo })
	if !has(r, "GARBAGE untracked stray.txt") || !strings.Contains(r.Summary, "untracked in "+w.repo+",") {
		t.Error(w.dump(r))
	}
}
