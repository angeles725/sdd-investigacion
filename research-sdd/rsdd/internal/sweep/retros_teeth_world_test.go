package sweep

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Teeth for the sweep itself (kit issue #2592): worlds whose answer moves with the threshold a mutant shifted.
// Clocks are the world's fixed now, so a file touched exactly d before now is exactly d old.

func TestKitDirectoryIsResolvedThroughSymlinks(t *testing.T) {
	w := newWorld(t)
	link := w.root + "/kit-link"
	w.must(os.Symlink(w.kit, link))
	w.kit = link
	r := w.run()
	if want := "sweep-retros: cannot find " + w.root + "/kit/TARGETS.md\n"; r.err != want || r.rc != cli.ExitOperational {
		t.Errorf("rc=%d stderr=%q, want %q", r.rc, r.err, want)
	}
}

func TestKitIsLocatedFromTheEnvironmentWithoutAKitOption(t *testing.T) {
	w := newWorld(t)
	var o, e strings.Builder
	rc := cli.Run(Commands, []string{"sweep", "retros"}, w.stdio(&o, &e))
	if rc == 0 || !strings.Contains(e.String(), "research-sdd kit not found") || o.Len() != 0 {
		t.Errorf("rc=%d stdout=%q stderr=%q: no kit is reachable from the sandbox", rc, o.String(), e.String())
	}
	w.put(w.kit+"/toolbelt/sweep-retros.sh", "#!/bin/sh\n")
	w.env["RESEARCH_SDD_KIT"] = w.kit
	o.Reset()
	e.Reset()
	rc = cli.Run(Commands, []string{"sweep", "retros"}, w.stdio(&o, &e))
	if want := "sweep-retros: cannot find " + w.kit + "/TARGETS.md\n"; rc != cli.ExitOperational || e.String() != want {
		t.Errorf("rc=%d stderr=%q, want the kit below RESEARCH_SDD_KIT: %q", rc, e.String(), want)
	}
}

// escalation runs one pending retro of the given age and reports whether it is ESCALATED.
func escalation(t *testing.T, ageDaysEnv string, age int64) string {
	t.Helper()
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "r1.md", pendingMarker, 1)
	w.touch(a+"/retros/r1.md", time.Duration(age)*time.Second)
	w.wire(a)
	w.targets(a)
	if ageDaysEnv != "" {
		w.env["RSDD_RETRO_AGE_DAYS"] = ageDaysEnv
	}
	for _, l := range strings.Split(w.run().out, "\n") {
		if strings.Contains(l, "age: ") {
			return l[strings.Index(l, "age: "):]
		}
	}
	t.Fatal("no pending row")
	return ""
}

func TestEscalationThreshold(t *testing.T) {
	const week = 7 * 86400
	for name, c := range map[string]struct {
		env  string
		age  int64
		want string
	}{
		"default, exactly 7d is not past it":    {"", week, "age: 7d"},
		"default, 8d is escalated":              {"", week + 86400, "age: 8d  ·  ESCALATED (aged 8d)"},
		"env 2, 2d is not past it":              {"2", 2 * 86400, "age: 2d"},
		"env 2, 3d is escalated":                {"2", 3 * 86400, "age: 3d  ·  ESCALATED (aged 3d)"},
		"env 0, 1d is escalated":                {"0", 86400, "age: 1d  ·  ESCALATED (aged 1d)"},
		"env not a number never escalates":      {"abc", 400 * 86400, "age: 400d"},
		"a 3d retro under the 7d default holds": {"", 3 * 86400, "age: 3d"},
	} {
		if got := escalation(t, c.env, c.age); got != c.want {
			t.Errorf("%s: %q, want %q", name, got, c.want)
		}
	}
}

func TestPendingQueueIsOldestFirst(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for name, age := range map[string]int64{"c.md": 9, "a.md": 2, "b.md": 5} {
		w.retro(a, name, pendingMarker, 1)
		w.touch(a+"/retros/"+name, time.Duration(age*86400)*time.Second)
	}
	w.wire(a)
	w.targets(a)
	var got []string
	for _, l := range strings.Split(w.run().out, "\n") {
		if rest, ok := strings.CutPrefix(l, "PENDING  "+a+"/retros/"); ok {
			got = append(got, rest)
		}
	}
	if strings.Join(got, " ") != "c.md b.md a.md" {
		t.Errorf("the oldest retro comes first: %v", got)
	}
}

// missingWorld holds an applied retro and a block, dated by mtime, under RSDD_MISSING_RETRO_GRACE_HOURS=1.
func missingWorld(t *testing.T, retroAge, blockAge int64) string {
	t.Helper()
	w := newWorld(t)
	a := w.tgt("targetA")
	w.put(a+"/retros/r1.md", retroText(appliedMarker, 1))
	w.put(a+"/t-block1.md", "# block\n")
	w.touch(a+"/retros/r1.md", time.Duration(retroAge)*time.Second)
	w.touch(a+"/t-block1.md", time.Duration(blockAge)*time.Second)
	w.wire(a)
	w.targets(a)
	w.env["RSDD_MISSING_RETRO_GRACE_HOURS"] = "1"
	return w.run().out
}

func TestMissingRetroBoundaries(t *testing.T) {
	const h, d = 3600, 86400
	for name, c := range map[string]struct {
		retro, block int64
		missing      bool
	}{
		"block newer than the retro and past the grace": {10 * d, 2 * h, true},
		"block exactly at the grace is not past it":     {10 * d, h, false},
		"block one second past the grace":               {10 * d, h + 1, true},
		"block and retro added at the same instant":     {5 * d, 5 * d, false},
		"block one second newer than the retro":         {5*d + 1, 5 * d, true},
		"block older than the retro":                    {5 * d, 6 * d, false},
	} {
		out := missingWorld(t, c.retro, c.block)
		if got := strings.Contains(out, "MISSING-RETRO: "); got != c.missing {
			t.Errorf("%s: MISSING-RETRO=%v, want %v\n%s", name, got, c.missing, out)
		}
	}
}

// TestGitDatesBeatMtime: the retro was added to git before the block, but its mtime is the newest. The epoch map
// of the repository decides, so the block is the later run and the retro does not cover it.
func TestGitDatesBeatMtime(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.put(a+"/retros/r1.md", retroText(appliedMarker, 1))
	w.commit(a, 10*day, "add retro")
	w.put(a+"/t-block1.md", "# block\n")
	w.commit(a, 5*day, "add block")
	w.touch(a+"/retros/r1.md", 0)
	w.touch(a+"/t-block1.md", 20*day)
	w.wire(a)
	w.targets(a)
	out := w.run().out
	if want := "MISSING-RETRO: " + a + " advanced with no retro for the latest run\n"; !strings.Contains(out, want) {
		t.Errorf("commit dates (retro 10d, block 5d) outrank the mtimes:\n%s", out)
	}
}

// TestEmptyRepositoryFallsBackToMtime: a work tree with no commit has no epoch map, so files are dated by mtime.
func TestEmptyRepositoryFallsBackToMtime(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.git(a, nil, "init", "-q")
	w.put(a+"/retros/r1.md", retroText(appliedMarker, 1))
	w.put(a+"/t-block1.md", "# block\n")
	w.touch(a+"/retros/r1.md", 10*day)
	w.touch(a+"/t-block1.md", 5*day)
	w.wire(a)
	w.targets(a)
	if out := w.run().out; !strings.Contains(out, "MISSING-RETRO: "+a) {
		t.Errorf("the block (5d) is newer than the retro (10d) by mtime:\n%s", out)
	}
}

func TestUnreadableSettingsAreCountedInTheWiringLine(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "r1.md", appliedMarker, 1)
	w.wire(a)
	w.must(os.Chmod(a+"/.claude/settings.json", 0))
	w.targets(a)
	out := w.run().out
	for _, want := range []string{
		"WARN: retro-gate wiring unknown — unreadable: " + a + "/.claude/settings.json\n",
		"Wiring: 0 wired / 0 wired-off-root / 0 unwired / 0 absent-settings / 1 unreadable — 1 targets checked.\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
}
