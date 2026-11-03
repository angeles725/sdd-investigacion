package sweep

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// Guard-to-test table for the pieces of the sweep that the scenario table does not exercise through its report
// (each guard was mutated by hand once; the mutant turns the named test red):
//
//	every `git log --diff-filter=A` call passes --no-renames        TestEveryAddDateCallPassesNoRenames
//	dating is independent of the user's diff.renames setting        TestRenamesSettingDoesNotChangeTheReport
//	-path '*/retros/*.md' matches the whole path, first /retros/    TestFindPredicates
//	-iname '*index*.md' excludes index files only                   TestFindPredicates
//	grace hours read like bash arithmetic (octal, wrap)             TestGraceSeconds
//	the six profile phases are measured on the injected clock       TestProfilePhases
//	a retro reachable twice is counted once                         TestRetroReachableTwiceCountsOnce
//	a target that is a symbolic link lists no retro (find -P)       TestSymlinkTargetListsNothing
//	an unreadable retro is announced, never read as zero deltas     TestUnreadableRetroIsAnnounced
//	retros of one age order bytewise                                TestTiesOrderBytewise
//	the envelope is jq's bytes                                      TestJSONEnvelopeBytes, TestJQString
//	the live retro template counts as ~0 deltas (old case 140)      TestLiveTemplateCountsZero

func TestEveryAddDateCallPassesNoRenames(t *testing.T) {
	src, err := os.ReadFile("retros.go")
	if err != nil {
		t.Fatal(err)
	}
	calls, withFlag := 0, 0
	for _, l := range strings.Split(string(src), "\n") {
		if strings.HasPrefix(strings.TrimSpace(l), "//") || !strings.Contains(l, `"--diff-filter=A"`) {
			continue
		}
		calls++
		if strings.Contains(l, `"--no-renames"`) {
			withFlag++
		}
	}
	if calls < 2 || calls != withFlag {
		t.Errorf("%d git log --diff-filter=A calls, %d with --no-renames; both the per-file date and the epoch map need it", calls, withFlag)
	}
}

// renamesWorld holds a renamed block and a retro, the shape whose dating depends on diff.renames without
// --no-renames (the rename commit is dated 2000, the file mtime is 2 days ago).
func renamesWorld(t *testing.T, renames string) (*world, string) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.put(a+"/t-block1.md", "# block\n")
	w.commit(a, deepPast, "add block")
	w.git(a, nil, "config", "diff.renames", renames)
	w.git(a, nil, "mv", "t-block1.md", "u-block1.md")
	w.commit(a, deepPast-365*day, "rename block")
	w.retro(a, "r1.md", pendingMarker, 1)
	w.commit(a, deepPast-2*365*day, "add retro")
	w.touch(a+"/u-block1.md", 2*day)
	w.wire(a)
	w.targets(a)
	return w, w.run().out
}

func TestRenamesSettingDoesNotChangeTheReport(t *testing.T) {
	_, on := renamesWorld(t, "true")
	_, off := renamesWorld(t, "false")
	// The two worlds live in different temp directories: compare with the root blanked.
	blank := func(s string) string { return regexp.MustCompile(`\S*/targetA`).ReplaceAllString(s, "A") }
	if blank(on) != blank(off) {
		t.Errorf("diff.renames changed the report\ntrue:\n%s\nfalse:\n%s", on, off)
	}
	if strings.Contains(on, "MISSING-RETRO") || !strings.Contains(on, "PENDING") {
		t.Errorf("the renamed block is dated from its rename commit, so the retro (added later) covers it:\n%s", on)
	}
}

func TestFindPredicates(t *testing.T) {
	for p, want := range map[string]bool{
		"/t/retros/a.md": true, "/t/x/retros/a.md": true, "/t/retros/sub/a.md": true, "/retros/.md": true,
		"/t/retros/a.txt": false, "/t/retros": false, "/t/retros/": false, "/t/aretros/a.md": false, "retros/a.md": false,
		"/x/retros/targetA/note.md": true, // the prefix of the target counts: the whole path is matched
	} {
		if got := inRetrosPath(p); got != want {
			t.Errorf("inRetrosPath(%q) = %v, want %v", p, got, want)
		}
	}
	for p, want := range map[string]bool{
		"/t/retros/RETROS-INDEX.md": true, "/t/retros/index.md": true, "/t/retros/my-Index-1.md": true,
		"/t/retros/a.md": false, "/t/index/a.md": false, "/t/retros/indexmd": false,
	} {
		if got := isIndexName(p); got != want {
			t.Errorf("isIndexName(%q) = %v, want %v", p, got, want)
		}
	}
	if notGitPath("/t/.git/retros/a.md") || !notGitPath("/t/.github/retros/a.md") {
		t.Error("only a .git path segment is excluded")
	}
}

func TestGraceSeconds(t *testing.T) {
	for v, want := range map[string]int64{"24": 86400, "0": 0, "010": 8 * 3600, "007": 7 * 3600, "1": 3600} {
		if got, ok := graceSeconds(v); !ok || got != want {
			t.Errorf("graceSeconds(%q) = %d, %v; want %d", v, got, ok, want)
		}
	}
	if _, ok := graceSeconds("08"); ok {
		t.Error("08 is not an octal number: bash rejects it")
	}
}

func TestProfilePhases(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "r1.md", pendingMarker, 1)
	w.put(a+"/t-block1.md", "# b\n")
	w.wire(a)
	w.targets(a)
	w.env["RSDD_PROFILE"] = "1"
	tick := w.now
	var o, e strings.Builder
	s := w.stdio(&o, &e)
	s.Clock = func() time.Time { tick = tick.Add(10 * time.Millisecond); return tick }
	if rc := cli.Run(Commands, []string{"sweep", "retros", "--kit", w.kit}, s); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	re := regexp.MustCompile(`(?m)^profile: ([a-z-]+) ([0-9]+)\.([0-9]{6})$`)
	got := map[string]float64{}
	var order []string
	for _, m := range re.FindAllStringSubmatch(e.String(), -1) {
		var v float64
		fmt.Sscanf(m[2]+"."+m[3], "%g", &v)
		got[m[1]] = v
		order = append(order, m[1])
	}
	if strings.Join(order, ",") != "pending-pass,waiver-pass,retro-newest-pass,block-newest-pass,wiring-pass,total" {
		t.Fatalf("phases %v\n%s", order, e.String())
	}
	if got["total"] < got["pending-pass"]+got["waiver-pass"]+got["wiring-pass"] || got["retro-newest-pass"] > got["waiver-pass"] || got["block-newest-pass"] > got["waiver-pass"] {
		t.Errorf("phases do not nest: %v", got)
	}
	if strings.Contains(o.String(), "profile:") {
		t.Error("profile lines belong on stderr")
	}
}

func TestRetroReachableTwiceCountsOnce(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a+"/sub", "r1.md", pendingMarker, 2)
	w.retro(a, "r0.md", "", 1)
	w.targets(a, a+"/sub", a)
	r := w.run()
	if !strings.Contains(r.out, "Summary: 2 pending / 2 retros across targets.") || strings.Count(r.out, "PENDING  ") != 2 {
		t.Errorf("a retro under two registered targets must count once:\n%s", r.out)
	}
}

func TestSymlinkTargetListsNothing(t *testing.T) {
	w := newWorld(t)
	real := w.tgt("real")
	w.retro(real, "r1.md", pendingMarker, 1)
	link := w.root + "/link"
	w.must(os.Symlink(real, link))
	w.targets(link)
	r := w.run()
	if !strings.Contains(r.out, "Summary: 0 pending / 0 retros across targets.") {
		t.Errorf("`find /link` lists the link alone; the sweep sees no retro through it:\n%s", r.out)
	}
}

func TestUnreadableRetroIsAnnounced(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "r1.md", pendingMarker, 1)
	w.must(os.Chmod(a+"/retros/r1.md", 0))
	w.targets(a)
	r := w.run()
	want := "retro-grammar: cannot read " + a + "/retros/r1.md (unreadable) — delta count is UNKNOWN, not zero\n"
	if r.err != want || r.rc != 0 || !strings.Contains(r.out, "Summary: 1 pending / 1 retros") {
		t.Errorf("rc=%d stderr=%q\n%s", r.rc, r.err, r.out)
	}
}

func TestTiesOrderBytewise(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	for _, n := range []string{"b.md", "B.md", "a.md", "_.md", "1.md"} {
		w.retro(a, n, pendingMarker, 1)
		w.touch(a+"/retros/"+n, 3*day)
	}
	w.targets(a)
	var got []string
	for _, l := range strings.Split(w.run().out, "\n") {
		if rest, ok := strings.CutPrefix(l, "PENDING  "+a+"/retros/"); ok {
			got = append(got, rest)
		}
	}
	if strings.Join(got, " ") != "1.md B.md _.md a.md b.md" {
		t.Errorf("order %v", got)
	}
}

func TestJSONEnvelopeBytes(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "p.md", pendingMarker, 3)
	w.touch(a+"/retros/p.md", 3*day)
	w.targets(a)
	r := w.run("--json")
	want := `{
  "schema": "research-sdd.sweep-retros/v1",
  "state": "ok",
  "counts": {
    "targets": 1,
    "targets_absent": 0,
    "targets_skipped": 0,
    "retros": 1,
    "pending": 1,
    "missing_retro": 0
  },
  "reason": null,
  "items": [
    {
      "kind": "pending-retro",
      "file": "` + a + `/retros/p.md",
      "target": "` + a + `",
      "deltas": 3,
      "deltas_state": "counted",
      "status": "pending",
      "age_days": 3,
      "age_state": "counted",
      "escalated": false,
      "warning": null
    }
  ]
}
`
	if r.out != want || r.rc != 0 || r.err != "" {
		t.Errorf("rc=%d stderr=%q\n got:\n%s\nwant:\n%s", r.rc, r.err, r.out, want)
	}
}

func TestJQString(t *testing.T) {
	for in, want := range map[string]string{
		"plain": `"plain"`, "a\"b\\c": `"a\"b\\c"`, "t\tn\nr\rb\bf\f": `"t\tn\nr\rb\bf\f"`, "\x01\x1f\x7f": `"\u0001\u001f\u007f"`,
		"é—<>&": `"é—<>&"`, "bad\xffbyte": "\"bad�byte\"", " ": "\" \"",
	} {
		if got := jqString(in); got != want {
			t.Errorf("jqString(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestLiveTemplateCountsZero(t *testing.T) {
	tmpl, err := os.ReadFile(kitroot.Path(t, "templates", "retro.template.md"))
	if err != nil {
		t.Fatal(err)
	}
	// The awk of the old case 140: keep the template's lead block (the > lines) of the delta section, drop every
	// other body line, put the honesty line before the next ## heading and drop the Honest verdict section.
	var out []string
	inDelta, injected, inHV := false, false, false
	for _, l := range strings.Split(string(tmpl), "\n") {
		switch {
		case strings.HasPrefix(l, "## Proposed kit deltas"):
			inDelta = true
			out = append(out, l)
			continue
		case strings.HasPrefix(l, "## ") && !strings.HasPrefix(l, "###"):
			if inDelta && !injected {
				out = append(out, "no new deltas; the kit already covers this run.")
				injected = true
			}
			inDelta = false
		}
		switch {
		case inDelta && strings.HasPrefix(l, ">"), inDelta && strings.TrimSpace(l) == "":
			out = append(out, l)
			continue
		case inDelta:
			continue
		}
		if strings.HasPrefix(l, "## Honest verdict") {
			inHV = true
		}
		if !inHV {
			out = append(out, l)
		}
	}
	w := newWorld(t)
	a := w.tgt("targetA")
	w.put(a+"/retros/r1.md", strings.Join(out, "\n"))
	w.wire(a)
	w.targets(a)
	r := w.run()
	if !strings.Contains(r.out, "~0 proposed deltas") {
		t.Errorf("the live template's lead block must read as an empty delta section:\n%s", r.out)
	}
	if !regexp.MustCompile("(?m)^> \\*\\*Provenance:\\*\\* base `[^`]+` · head `[^`]+` · gate-run `[^`]+` · reruns `[^`]+`").Match(tmpl) {
		t.Error("the retro template lost its provenance line (kit issue #1712, old case 140p)")
	}
}
