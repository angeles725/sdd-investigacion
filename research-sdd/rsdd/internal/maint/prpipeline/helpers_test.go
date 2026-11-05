package prpipeline

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// result is one run: stdout, stderr and the exit code.
type result struct {
	out, err string
	rc       int
}

var (
	degradedLine = regexp.MustCompile(`(?m)^DEGRADED: .*\n?`)
	flockCall    = regexp.MustCompile(`(?m)^flock -w [0-9]+ 9\n?`)
	gitDirFlag   = regexp.MustCompile(`(?m)^git -C \S+ `)
)

// fakeStep is a stand-in for rdd-start / rdd-drive, the twin of the stub scripts the legacy side runs: it records one
// call-log line, prints the file named by outEnv, and exits with the rc named by rcEnv (default 0).
func fakeStep(name, rcEnv, outEnv string) Step {
	return func(args []string, s cli.Stdio) int {
		if f, err := os.OpenFile(s.Env("SHIM_STATE")+"/calls.log", os.O_APPEND|os.O_WRONLY, 0); err == nil {
			_, _ = f.WriteString(name + " " + strings.Join(args, " ") + "\n")
			f.Close()
		}
		if p := s.Env(outEnv); p != "" {
			if b, err := os.ReadFile(p); err == nil {
				_, _ = s.Out.Write(b)
			}
		}
		rc, _ := strconv.Atoi(s.Env(rcEnv))
		return rc
	}
}

func fakes() (Step, Step) {
	return fakeStep("RDDSTART", "STUB_START_RC", "STUB_START_OUT"), fakeStep("RDDDRIVE", "STUB_DRIVE_RC", "STUB_DRIVE_OUT")
}

// stubScript is the legacy side's kit-rdd-start.sh / kit-rdd-drive.sh: same recording, same knobs as fakeStep.
const stubScript = `#!/usr/bin/env bash
echo "NAME $*" >> "$SHIM_STATE/calls.log"
[ -z "${OUTV:-}" ] || cat "$OUTV"
exit "${RCV:-0}"
`

func writeStubs(t *testing.T, dir string) {
	t.Helper()
	for _, s := range [][4]string{
		{"kit-rdd-start.sh", "RDDSTART", "STUB_START_OUT", "STUB_START_RC"},
		{"kit-rdd-drive.sh", "RDDDRIVE", "STUB_DRIVE_OUT", "STUB_DRIVE_RC"},
	} {
		body := strings.NewReplacer("NAME", s[1], "OUTV", s[2], "RCV", s[3]).Replace(stubScript)
		if err := os.WriteFile(filepath.Join(dir, s[0]), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
}

// happy scripts the all-green pipeline. A case's own rules come first (the first matching rule wins); every git glob
// starts with `*` because the Go side runs `git -C <worktree> ...`.
func happy(w *kitworld.World) {
	w.Rule("git", "*status --porcelain*", 0, "", 0, "")
	w.Rule("git", "*fetch*", 0, "", 0, "")
	w.Rule("git", "*merge-base --is-ancestor*", 0, "", 0, "")
	w.Rule("git", "*merge -q --no-edit*", 0, "", 0, "")
	w.Rule("git", "*ls-files -u*", 0, "", 0, "")
	w.Rule("git", "*merge --abort*", 0, "", 0, "")
	w.Rule("git", "*push*", 0, "", 0, "")
	w.Rule("git", "*rev-parse --short HEAD", 0, "head.txt", 0, "")
	w.Rule("flock", "*", 0, "", 0, "")
	w.Rule("gh", "pr checks*", 0, "pr-checks-pass.txt", 0, "")
	w.Rule("gh", "pr view*", 0, "pr-state-merged.txt", 0, "")
	w.Rule("merge-gate.sh", "*", 0, "merge-gate-merged.txt", 0, "")
}

// prepare gives the world a run-all.sh stub and the merge-gate shim, and returns the env entry naming the latter.
func prepare(t *testing.T, w *kitworld.World) string {
	t.Helper()
	d := w.Wt + "/research-sdd/toolbelt/tests"
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	body := "#!/usr/bin/env bash\necho \"RUNALL $*\" >> \"$SHIM_STATE/calls.log\"\n"
	if err := os.WriteFile(d+"/run-all.sh", []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(w.Dir, "merge-gate.sh")
	if err := os.Symlink(filepath.Join(w.Fix, "shim.sh"), p); err != nil && !os.IsExist(err) {
		t.Fatal(err)
	}
	return "KIT_MERGE_GATE=" + p
}

// goRun runs the command in w with the fake review steps.
func goRun(t *testing.T, w *kitworld.World, args []string, extra ...string) result {
	t.Helper()
	extra = append([]string{prepare(t, w)}, extra...)
	return goRunEnv(w, args, extra...)
}

func goRunEnv(w *kitworld.World, args []string, extra ...string) result {
	start, drive := fakes()
	s, o, e := w.Stdio(w.Wt, extra...)
	rc := run(args, s, deps{start: start, drive: drive, sleep: func(time.Duration) {}})
	return result{o.String(), e.String(), rc}
}

func count(calls, prefix string) int {
	n := 0
	for _, l := range strings.Split(calls, "\n") {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}
