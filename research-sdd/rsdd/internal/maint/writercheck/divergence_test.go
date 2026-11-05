package writercheck

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The intended divergences from the bash tool (listed in tool-registry.d/kit-writer-check.md), each pinned here.

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// onlyGit is a PATH holding git alone (plus bash when asked): none of grep, awk, sort, mktemp, timeout or sed.
func onlyGit(t *testing.T, k *kase, withBash bool) []string {
	t.Helper()
	bin := k.root + "/onlygit"
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	tools := []string{"git"}
	if withBash {
		tools = append(tools, "bash")
	}
	for _, tool := range tools {
		for _, d := range strings.Split(sysPath, ":") {
			if _, err := os.Stat(d + "/" + tool); err == nil {
				if err := os.Symlink(d+"/"+tool, bin+"/"+tool); err != nil {
					t.Fatal(err)
				}
				break
			}
		}
	}
	return []string{"PATH=" + bin}
}

func TestNoLongerNeedsGrepAwkSortMktempTimeoutSed(t *testing.T) {
	k := newKase(t)
	k.touch(alpha)
	path := onlyGit(t, k, false)
	if r := k.goRun(path, "--repo", k.dir, "--base", "base", "--print-binding"); r.rc != 0 || !strings.HasPrefix(r.out, "# writer-check: head=") {
		t.Errorf("--print-binding with only git on PATH: rc %d out %q err %q", r.rc, r.out, r.err)
	}
	if r := k.goRun(path, "--classify", tb+"/x.sh"); r.rc != 0 || r.out != "production "+tb+"/x.sh\n" {
		t.Errorf("--classify: rc %d out %q", r.rc, r.out)
	}
}

func TestGitIsTheOnlyUpFrontDependency(t *testing.T) {
	k := newKase(t)
	k.env = append(k.env, "PATH="+k.root+"/empty")
	r := k.goRun(nil, "--repo", k.dir, "--base", "base")
	if r.rc != 2 || r.err != "degraded: kit-writer-check: git not found on PATH\n" {
		t.Errorf("rc %d err %q", r.rc, r.err)
	}
}

func TestBashIsProbedWhereItIsUsed(t *testing.T) {
	k := newKase(t)
	k.touch(alpha)
	env := append(onlyGit(t, k, false), "KIT_WRITER_CHECK_IMPACT="+k.impact)
	r := k.goRun(env, "--repo", k.dir, "--base", "base")
	if r.rc != 2 || !strings.Contains(r.err, "degraded: kit-writer-check: bash not found on PATH") {
		t.Errorf("check mode without bash: rc %d err %q", r.rc, r.err)
	}
	r = k.goRun(env, "--repo", k.dir, "--write-teeth-log", k.root+"/l", "--base", "base", ts+"/a.test.sh")
	if r.rc != 1 || !strings.Contains(r.err, "FAIL  "+ts+"/a.test.sh: exit 127") {
		t.Errorf("write mode without bash: rc %d err %q", r.rc, r.err)
	}
}

// A path with a space is read whole and an added line that looks like a file header does not hide the lines after
// it: both used to be mis-attributed by the awk of the bash tool.
func TestNameKillAttributionToTheRightFile(t *testing.T) {
	k := newKase(t)
	k.write(tb+"/my file.sh", "echo one\npkill -f spaced\n")
	k.write(tb+"/hdr.sh", "++ b/notes.md\npkill -f after-header\n")
	k.write(tb+"/q\"uote.sh", "pkill -f quoted\n")
	k.commit("odd names")
	stub := k.root + "/impact-stub.sh" // suite-impact.sh itself cannot read a path with a space
	execfile.Write(t, stub, "#!/usr/bin/env bash\necho 'Impacted: 0 of 0 suites (stub)'\n")
	r := k.goRun([]string{"KIT_WRITER_CHECK_IMPACT=" + stub}, "--repo", k.dir, "--base", "base")
	for _, want := range []string{
		"name-kill " + tb + "/my file.sh:2 (name-based process kill)",
		"name-kill " + tb + "/hdr.sh:2 (name-based process kill)",
		"name-kill " + tb + "/q\"uote.sh:1 (name-based process kill)",
	} {
		if !strings.Contains(r.out, want+"\n") {
			t.Errorf("missing %q in rc %d out:\n%s\nerr:\n%s", want, r.rc, r.out, r.err)
		}
	}
}

// A suite that outlives the timeout takes its whole process group with it, not just the direct child.
func TestTimeoutStopsTheSuitesProcessGroup(t *testing.T) {
	k := newKase(t)
	pidFile := k.root + "/child.pid"
	body := "#!/usr/bin/env bash\nsleep 60 &\necho $! > " + pidFile + "\nwait\n"
	k.write(ts+"/slow.test.sh", body)
	start := time.Now()
	r := k.goRun([]string{"KIT_WRITER_CHECK_TIMEOUT=1"}, "--repo", k.dir, "--write-teeth-log", k.root+"/l", "--base", "base", ts+"/slow.test.sh")
	if r.rc != 1 || !strings.Contains(r.err, "timed out after 1s") {
		t.Fatalf("rc %d err %q", r.rc, r.err)
	}
	if d := time.Since(start); d > 20*time.Second {
		t.Errorf("the run took %v", d)
	}
	raw, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 50 && syscall.Kill(pid, 0) == nil; i++ { // the zombie of a reaped group leader is gone at once
		time.Sleep(100 * time.Millisecond)
	}
	if syscall.Kill(pid, 0) == nil {
		_ = syscall.Kill(pid, syscall.SIGKILL)
		t.Errorf("the suite's background child %d survived the timeout", pid)
	}
}

// Without KIT_WRITER_CHECK_IMPACT the kit's own suite-impact.sh is resolved like the portable hooks do.
func TestImpactScriptFallsBackToTheResolvedKit(t *testing.T) {
	k := newKase(t)
	k.touch(alpha)
	kit := kitroot.Dir(t)
	if r := k.goRun([]string{"RESEARCH_SDD_KIT=" + kit}, "--repo", k.dir, "--base", "base"); r.rc != 1 || !strings.HasPrefix(r.out, "Required suites: 2\n") {
		t.Errorf("with the kit resolved: rc %d out %q err %q", r.rc, r.out, r.err)
	}
	r := k.goRun([]string{"RESEARCH_SDD_KIT=" + k.root + "/nokit"}, "--repo", k.dir, "--base", "base")
	if r.rc != 2 || r.err != "degraded: kit-writer-check: suite-impact.sh not found: (set KIT_WRITER_CHECK_IMPACT)\n" {
		t.Errorf("without a kit: rc %d err %q", r.rc, r.err)
	}
}

// A degraded impact map must never read as an empty requirement set, whatever the way it fails.
func TestImpactFailureIsDegradedWithItsMessage(t *testing.T) {
	k := newKase(t)
	k.touch(alpha)
	bad := k.root + "/bad.sh"
	execfile.Write(t, bad, "#!/usr/bin/env bash\necho boom >&2\necho and more >&2\nexit 3\n")
	r := k.goRun([]string{"KIT_WRITER_CHECK_IMPACT=" + bad}, "--repo", k.dir, "--base", "base")
	if r.rc != 2 || r.err != "degraded: kit-writer-check: suite-impact.sh exited 3: boom and more \n" {
		t.Errorf("rc %d err %q", r.rc, r.err)
	}
}
