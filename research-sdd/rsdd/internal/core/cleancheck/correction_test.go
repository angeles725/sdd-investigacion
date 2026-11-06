package cleancheck

import (
	"os"
	"runtime"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// fileSum hashes a multi-hundred-megabyte file without holding it: the legacy `sha256sum < file` streamed.
func TestFileSumStreamsLargeFiles(t *testing.T) {
	const size = 300 << 20
	f, err := os.CreateTemp(t.TempDir(), "big")
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(size); err != nil {
		t.Skip("no sparse files here:", err)
	}
	f.Close()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	sum, ok := fileSum(f.Name())
	runtime.ReadMemStats(&after)
	if !ok || len(sum) != 64 {
		t.Fatalf("%q %v", sum, ok)
	}
	if got := after.TotalAlloc - before.TotalAlloc; got > 32<<20 {
		t.Errorf("hashing a %d MiB file allocated %d MiB", size>>20, got>>20)
	}
}

func TestFileSumValue(t *testing.T) {
	p := t.TempDir() + "/f"
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	const want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
	if sum, ok := fileSum(p); !ok || sum != want {
		t.Errorf("%q %v", sum, ok)
	}
	if _, ok := fileSum(p + ".missing"); ok {
		t.Error("a missing file has a sum")
	}
}

// A git that exits 0 after its output was cut at the cap must not read as a complete listing.
func TestOutputCapIsNotACompleteListing(t *testing.T) {
	for name, c := range map[string]struct {
		in   proc.Result
		want int
	}{
		"exit 0 cut at the cap": {proc.Result{Stdout: []byte("a\x00"), ReturnCode: 0, Reason: proc.ReasonOutputCap}, 125},
		"cut and killed":        {proc.Result{ReturnCode: -9, Reason: proc.ReasonOutputCap}, 125},
		"timeout":               {proc.Result{ReturnCode: 0, Reason: proc.ReasonTimeout}, 124},
		"killed by a signal":    {proc.Result{ReturnCode: -11}, 139},
		"plain success":         {proc.Result{Stdout: []byte("a\x00")}, 0},
		"plain failure":         {proc.Result{ReturnCode: 128}, 128},
	} {
		if got := settle(c.in); got.rc != c.want {
			t.Errorf("%s: rc %d, want %d", name, got.rc, c.want)
		}
	}
}

// Every path is resolved against Options.Cwd, never the process's.
func TestRelativePathsUseOptionsCwd(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.root+"/evid/rollback-1.tar", "x")
	w.ago(24*30, w.root+"/evid/rollback-1.tar")
	r := w.check(func(o *Options) { o.Evidence = "evid"; o.Cwd = w.root })
	if !has(r, "WARN stale-backup evid/rollback-1.tar age=30d retention=14d") || len(r.Degraded) != 0 {
		t.Errorf("%s", w.dump(r))
	}
	if !strings.Contains(r.Summary, "evidence: 1 dir(s) scanned, 1 older than 14d") {
		t.Errorf("%s", r.Summary)
	}
}

func TestZeroNowIsATypedRefusal(t *testing.T) {
	w := newWorld(t)
	r := w.check(func(o *Options) { o.Now = nil })
	if r.Exit != 2 || r.Verdict != Refused || !strings.Contains(r.Stderr(), "Options.Now") {
		t.Errorf("%s", w.dump(r))
	}
}

// A symlinked sources/probes is not followed (find <dir> -type f did not): its manifest cannot exempt a script.
func TestSymlinkedProbesAreNotFollowed(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.root+"/outside/b1/SCRIPTS-MANIFEST.md", "| `run.sh` | "+strings.Repeat("0", 64)+" | x |\n")
	w.writeAt(w.scratch+"/run.sh", "echo\n")
	w.mkdir(w.repo + "/sources")
	if err := os.Symlink(w.root+"/outside", w.repo+"/sources/probes"); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if !has(r, "GARBAGE untracked sources/probes") && !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/run.sh") {
		t.Fatalf("%s", w.dump(r))
	}
	if !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/run.sh") {
		t.Errorf("manifest outside the target was read:\n%s", w.dump(r))
	}
}

// manifestFor is a SCRIPTS-MANIFEST.md that lists run.sh.
func manifestFor() string { return "| `run.sh` | " + strings.Repeat("0", 64) + " | x |\n" }

// A symlinked sources (an intermediate component of sources/probes) is not followed either: a manifest it reaches
// outside the target must not exempt a scratchpad script.
func TestSymlinkedSourcesIsNotFollowed(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.root+"/elsewhere/probes/b1/SCRIPTS-MANIFEST.md", manifestFor())
	w.writeAt(w.scratch+"/run.sh", "echo\n")
	if err := os.Symlink(w.root+"/elsewhere", w.repo+"/sources"); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Verdict != Findings || r.Exit != 1 || !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/run.sh") {
		t.Errorf("manifest behind a symlinked sources was read:\n%s", w.dump(r))
	}
	if len(r.Degraded) != 0 || len(r.Absent) != 1 || r.Absent[0].Kind != AbsentKeepList {
		t.Errorf("unexpected typed state: absent %v degraded %v", r.Absent, r.Degraded)
	}
}

// Pinned: a symlinked sources is refused even when it points at a directory INSIDE the target. The rule is about the
// path component, not about where it leads, so the outcome is the same as for a link that leaves the target.
func TestSymlinkedSourcesInsideTargetIsNotFollowed(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.repo+"/real/probes/b1/SCRIPTS-MANIFEST.md", manifestFor())
	w.writeAt(w.scratch+"/run.sh", "echo\n")
	if err := os.Symlink(w.repo+"/real", w.repo+"/sources"); err != nil {
		t.Fatal(err)
	}
	r := w.check(func(o *Options) { o.Scratchpad = w.scratch })
	if r.Verdict != Findings || r.Exit != 1 || !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/run.sh") {
		t.Errorf("symlinked sources inside the target was followed:\n%s", w.dump(r))
	}
}

// An empty Options.Cwd would resolve every relative path against the process or "/": a typed refusal.
func TestEmptyCwdIsATypedRefusal(t *testing.T) {
	w := newWorld(t)
	r := w.check(func(o *Options) { o.Cwd = "" })
	if r.Exit != 2 || r.Verdict != Refused || r.Summary != "" || !strings.Contains(r.Stderr(), "Options.Cwd") {
		t.Errorf("%s", w.dump(r))
	}
}
