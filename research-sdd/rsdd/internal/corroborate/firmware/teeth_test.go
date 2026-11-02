//go:build linux

package firmware

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func TestResolveParentFollowsLinksAndSplitsTheName(t *testing.T) {
	cwd := mustEval(t, t.TempDir())
	if err := os.MkdirAll(filepath.Join(cwd, "d", "e"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(cwd, "d"), filepath.Join(cwd, "ln")); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ output, parent, name string }{
		{"out", cwd, "out"},
		{"./out/", cwd, "out"},
		{"d/out", filepath.Join(cwd, "d"), "out"},
		{"ln/out", filepath.Join(cwd, "d"), "out"},
		{"d//e/./out", filepath.Join(cwd, "d", "e"), "out"},
		{cwd + "/out", cwd, "out"},
		{cwd + "/d/out", filepath.Join(cwd, "d"), "out"},
		{"/out", "/", "out"},
		{"/", "/", ""},
		{".", cwd, ""},
	} {
		parent, name, err := resolveParent(tc.output, cwd)
		if err != nil || parent != tc.parent || name != tc.name {
			t.Errorf("resolveParent(%q) = (%q, %q, %v), want (%q, %q, nil)", tc.output, parent, name, err, tc.parent, tc.name)
		}
	}
	want := "[Errno 2] No such file or directory: '" + filepath.Join(cwd, "missing") + "'"
	if _, _, err := resolveParent("missing/out", cwd); err == nil || err.Error() != want {
		t.Errorf("a missing parent: err = %v, want %q", err, want)
	}
}

func TestCountFilesCountsRegularFilesThroughLinks(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"a", "sub/b", "sub/deep/c"} {
		p := filepath.Join(dir, f)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(dir, "a"), filepath.Join(dir, "link-to-file")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(dir, "gone"), filepath.Join(dir, "dangling")); err != nil {
		t.Fatal(err)
	}
	if n, err := countFiles(dir); err != nil || n != 4 {
		t.Errorf("countFiles = %d, %v; want 4 (three files and a link to a file)", n, err)
	}
	if _, err := countFiles(filepath.Join(dir, "missing")); err == nil {
		t.Error("an unreadable root must be an error, not a zero")
	}
}

func TestProbeVersionBoundsEachProbeAndAsksHelpThenVersion(t *testing.T) {
	stage := t.TempDir()
	if err := os.MkdirAll(filepath.Join(stage, "engine"), 0o755); err != nil {
		t.Fatal(err)
	}
	var calls []string
	run := func(argv []string, d time.Duration) (runRecord, []string, error) {
		calls = append(calls, strings.Join(argv, " ")+"@"+d.String())
		text := "no banner"
		if argv[1] == "--version" {
			text = "binwalk 2.4.1"
		}
		return runRecord{}, nil, os.WriteFile(filepath.Join(stage, "engine/stdout.txt"), []byte(text), 0o600)
	}
	v, err := probeVersion(run, stage, 7, false)
	if err != nil || v != "2.4.1" {
		t.Fatalf("version = %q, %v", v, err)
	}
	if got := strings.Join(calls, ","); got != "engine/binwalk --help@7s,engine/binwalk --version@7s" {
		t.Errorf("probe calls = %s", got)
	}
}

func TestReportNamesTheVerifiedManifestAndTheCleanExit(t *testing.T) {
	w := newWorld(t)
	w.useExplicit(w.analyzer("v2fake", v2Banner))
	w.mustRun(w.input(), w.path("a"))
	r := w.report("a")
	var manifest struct {
		Identity string `json:"identity"`
	}
	if err := json.Unmarshal(mustRead(t, w.path("a/engine/analysis-manifest.v1.json")), &manifest); err != nil {
		t.Fatal(err)
	}
	if id, _ := at(t, r, "engine", "manifest_identity").(string); id == "" || id != manifest.Identity {
		t.Errorf("manifest_identity = %q, the manifest says %q", id, manifest.Identity)
	}
	if at(t, r, "engine", "run", "exit_code") != float64(0) || at(t, r, "engine", "run", "signal") != nil {
		t.Errorf("run = %v, want exit code 0 and no signal", at(t, r, "engine", "run"))
	}
}

func TestSlowVersionProbeIsNotCutShort(t *testing.T) {
	t.Parallel() // waits on real timers; overlapping them keeps the teeth run inside the CI job cap
	w := newWorld(t)
	w.useOverride(w.analyzer("slow-banner", "#!/bin/sh\nsleep 0.4\n[ \"$1\" = --help ] && { echo 'Binwalk v2.3.3'; exit; }\nprintf '0 0x0 x\\n'\n"))
	w.mustRun(w.input(), w.path("out"))
	if at(t, w.report("out"), "engine", "version") != "2.3.3" {
		t.Errorf("version = %v", at(t, w.report("out"), "engine", "version"))
	}
}

func TestDiagnosticCapCutsTheTwoStreamsJointly(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("two", fakeBinwalk("head -c 3000 /dev/zero | tr '\\000' a\nhead -c 3000 /dev/zero | tr '\\000' b >&2\nsleep 5")))
	if code := w.run(w.input(), w.path("out"), "--max-diagnostic-bytes", "4096"); code != 1 {
		t.Fatalf("exit %d, stderr %q", code, w.err.String())
	}
	if got := mustRead(t, w.path("out/engine/stdout.txt")); string(got) != strings.Repeat("a", 3000) {
		t.Errorf("stdout.txt has %d bytes, want the 3000 written", len(got))
	}
	if got := mustRead(t, w.path("out/engine/stderr.txt")); string(got) != strings.Repeat("b", 1096) {
		t.Errorf("stderr.txt has %d bytes, want the 1096 left in the 4096 budget", len(got))
	}
	if got := strings.Join(strs(t, at(t, w.report("out"), "errors")), ","); got != "diagnostic-cap" {
		t.Errorf("errors = %q", got)
	}
}

func TestOutputExactlyAtTheCapIsReportedEvenWhenTheAnalyzerExitsFirst(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("exact", fakeBinwalk("head -c 4096 /dev/zero | tr '\\000' a")))
	if code := w.run(w.input(), w.path("out"), "--max-diagnostic-bytes", "4096"); code != 1 {
		t.Fatalf("exit %d, stderr %q", code, w.err.String())
	}
	if got := strings.Join(strs(t, at(t, w.report("out"), "errors")), ","); got != "diagnostic-cap" {
		t.Errorf("errors = %q, want diagnostic-cap", got)
	}
	if got := mustRead(t, w.path("out/engine/stdout.txt")); len(got) != 4096 {
		t.Errorf("stdout.txt has %d bytes, want 4096", len(got))
	}
}

// startGroup starts script as the leader of its own process group and reaps it in the background.
func startGroup(t *testing.T, script string) (pid int, g *proc.Group, exited chan struct{}) {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", script)
	proc.SetNewGroup(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pid = cmd.Process.Pid
	g = &proc.Group{}
	g.Record(pid)
	exited = make(chan struct{})
	go func() { _ = cmd.Wait(); close(exited) }()
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })
	return pid, g, exited
}

func TestStopGroupReturnsAsSoonAsTheGroupAnswersTerm(t *testing.T) {
	pid, g, exited := startGroup(t, "exec sleep 30")
	time.Sleep(100 * time.Millisecond)
	start := time.Now()
	stopGroup(g, pid, time.Now)
	if d := time.Since(start); d > 300*time.Millisecond {
		t.Errorf("stopGroup took %v for a group that dies on TERM", d)
	}
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Error("the group is still alive")
	}
}

func TestStopGroupGivesTermAHalfSecondBeforeKill(t *testing.T) {
	t.Parallel() // waits on real timers; overlapping them keeps the teeth run inside the CI job cap
	marker := filepath.Join(t.TempDir(), "term-handled")
	pid, g, exited := startGroup(t, "trap 'touch "+marker+"; exit 0' TERM\nsleep 30 &\nwait")
	time.Sleep(300 * time.Millisecond)
	stopGroup(g, pid, time.Now)
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Fatal("the group is still alive")
	}
	if _, err := os.Stat(marker); err != nil {
		t.Errorf("the TERM handler did not get to run before KILL: %v", err)
	}
}

func TestStopGroupKillsAGroupThatIgnoresTerm(t *testing.T) {
	t.Parallel() // waits on real timers; overlapping them keeps the teeth run inside the CI job cap
	pid, g, exited := startGroup(t, "trap '' TERM\nsleep 30")
	time.Sleep(300 * time.Millisecond)
	start := time.Now()
	stopGroup(g, pid, time.Now)
	select {
	case <-exited:
	case <-time.After(3 * time.Second):
		t.Fatal("a group that ignores TERM survived stopGroup")
	}
	if d := time.Since(start); d < 400*time.Millisecond {
		t.Errorf("KILL came after %v, before TERM had its half second", d)
	}
}

func TestIsPySpaceCoversTheFourAsciiSeparators(t *testing.T) {
	for r, want := range map[rune]bool{0x1b: false, 0x1c: true, 0x1d: true, 0x1e: true, 0x1f: true, 0x20: true, 'a': false, 0x85: true, 0x3000: true} {
		if got := isPySpace(r); got != want {
			t.Errorf("isPySpace(%#x) = %v, want %v", r, got, want)
		}
	}
	if got := strings.Join(strings.FieldsFunc("a\x1cb\x1fc", isPySpace), "|"); got != "a|b|c" {
		t.Errorf("fields = %q", got)
	}
}

func TestDigitValueIsThePositionInsideTheBlockOfTen(t *testing.T) {
	for r, want := range map[rune]int{
		'0': 0, '9': 9, '٠': 0, '٩': 9, '۰': 0, '۹': 9, '०': 0, '९': 9, '０': 0, '９': 9,
		0x1d7ce: 0, 0x1d7d7: 9, 0x1d7ff: 9, 0x1d7d8: 0, 0x104a0: 0, 0x104a9: 9, 'a': 0,
	} {
		if got := digitValue(r); got != want {
			t.Errorf("digitValue(%#x) = %d, want %d", r, got, want)
		}
	}
	for _, rg := range unicode.Nd.R16 {
		for r := rune(rg.Lo); r <= rune(rg.Hi); r++ {
			if want := int(r-rune(rg.Lo)) % 10; digitValue(r) != want {
				t.Fatalf("digitValue(%#x) = %d, want %d", r, digitValue(r), want)
			}
		}
	}
	for _, rg := range unicode.Nd.R32 {
		for r := rune(rg.Lo); r <= rune(rg.Hi); r++ {
			if want := int(r-rune(rg.Lo)) % 10; digitValue(r) != want {
				t.Fatalf("digitValue(%#x) = %d, want %d", r, digitValue(r), want)
			}
		}
	}
	if got := decimal("٠١٢٣٤٥٦٧٨٩").String(); got != "123456789" {
		t.Errorf("decimal = %s", got)
	}
}

func TestPySplitlinesCarriageReturnsAtTheEdges(t *testing.T) {
	for in, want := range map[string]string{
		"a\r": "a", "a\rb": "a|b", "a\r\nb": "a|b", "\n\rX": "||X", "\r\rX": "||X", "\r\n\r\nX": "||X", "a\r\n": "a",
	} {
		if got := strings.Join(pySplitlines(in), "|"); got != want {
			t.Errorf("pySplitlines(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEqualFindingsKeepTheirInputOrder(t *testing.T) {
	sigs, _ := parseFindings("5 0x5 same\n05 0x05 same\n5 0x5 same\n")
	if len(sigs) != 3 {
		t.Fatalf("signatures = %v", sigs)
	}
	sigs, _ = parseFindings("7 0x7 b\n7 0x7 a\n3 0x3 z\n")
	if got := sigs[0].Description + sigs[1].Description + sigs[2].Description; got != "zab" {
		t.Errorf("order = %q, want offset first, then description", got)
	}
}

func TestStatOfScalesSecondsAndAddsNanoseconds(t *testing.T) {
	var st syscall.Stat_t
	st.Dev, st.Ino, st.Mode, st.Size = 1, 2, 3, 4
	st.Mtim.Sec, st.Mtim.Nsec = 5, 6
	st.Ctim.Sec, st.Ctim.Nsec = 7, 8
	want := statTuple{1, 2, 3, 4, 5_000_000_006, 7_000_000_008}
	if got := statOf(&st); got != want {
		t.Errorf("statOf = %+v, want %+v", got, want)
	}
}

func TestParentOfReadsTheSecondFieldAfterTheLastParenthesis(t *testing.T) {
	for _, tc := range []struct {
		stat string
		ppid int
		ok   bool
	}{
		{"42 (sh) S 7 42 42 0", 7, true},
		{"42 (a b) c) S 9 1", 9, true},
		{"42 (sh) S 7", 7, true},
		{") S 5", 5, true},
		{"42 (sh) S", 0, false},
		{"42 (sh)", 0, false},
		{"42 sh S 7", 0, false},
		{"42 (sh) S x 1", 0, false},
	} {
		if ppid, ok := parentOf([]byte(tc.stat)); ppid != tc.ppid || ok != tc.ok {
			t.Errorf("parentOf(%q) = (%d, %v), want (%d, %v)", tc.stat, ppid, ok, tc.ppid, tc.ok)
		}
	}
}

func TestResolveFDFollowsTheDescriptorNotThePath(t *testing.T) {
	dir := mustEval(t, t.TempDir())
	old, moved := filepath.Join(dir, "old"), filepath.Join(dir, "moved")
	if err := os.WriteFile(old, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := openNoFollow(old)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if got := resolveFD(f, old); got != old {
		t.Errorf("resolveFD = %q, want %q", got, old)
	}
	if err := os.Rename(old, moved); err != nil {
		t.Fatal(err)
	}
	if got := resolveFD(f, old); got != moved {
		t.Errorf("after a rename resolveFD = %q, want the descriptor's file %q", got, moved)
	}
}

func TestStagingKeepsAReadFailure(t *testing.T) {
	// /proc/self/mem is a regular file whose first page cannot be read: the copy fails with EIO.
	target := filepath.Join(t.TempDir(), "staged")
	_, _, err := stageTrusted("/proc/self/mem", target, "x", 0o500, nil, nil)
	var fe *fsx.Error
	if !errors.As(err, &fe) || !errors.Is(err, fsx.ErrStageIO) {
		t.Fatalf("err = %v, want a stage I/O failure", err)
	}
	if _, serr := os.Lstat(target); serr == nil {
		t.Error("the half-written target was left behind")
	}
}

func TestRootOwnedPathAnalyzerIsReportedAsRootOwned(t *testing.T) {
	w := newWorld(t)
	// A root-owned program stands in for the PATH-selected binwalk (its bytes are staged, never run); the fake
	// sandbox runs the banner-answering script in its place.
	if fi, err := os.Stat(mustEval(t, "/bin/true")); err != nil {
		t.Skip("no /bin/true")
	} else if st, ok := fi.Sys().(*syscall.Stat_t); !ok || st.Uid != 0 {
		t.Skip("/bin/true is not root-owned here")
	}
	script := w.exe("v2script", v2Banner)
	w.exe("bin/bwrap", "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != \"--\" ]; do shift; done\nshift\ncase \"$1\" in\n/bin/sh) exit 0 ;;\nengine/binwalk) shift; exec '"+script+"' \"$@\" ;;\nesac\nexec \"$@\"\n")
	w.mkdir("rootbin")
	if err := os.Symlink("/bin/true", w.path("rootbin/binwalk")); err != nil {
		t.Fatal(err)
	}
	w.env["PATH"] = w.path("rootbin") + ":/usr/bin:/bin"
	w.mustRun(w.input(), w.path("out"))
	r := w.report("out")
	if at(t, r, "status") != "complete" || at(t, r, "engine", "trust") != "root-owned" || at(t, r, "engine", "test_override") != false {
		t.Fatalf("engine = %v, status %v", at(t, r, "engine"), at(t, r, "status"))
	}
	limits := strs(t, at(t, r, "limitations"))
	if !contains(limits, "The distro Binwalk package, Python dependencies, and magic database are read-only") || contains(limits, "not root-owned") || contains(limits, "test analyzer") {
		t.Errorf("limitations = %v", limits)
	}
	w.verifyManifest("out")
}
