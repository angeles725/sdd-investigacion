//go:build unix && !nodiff

package show

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/parallelfloor"
)

// The differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, verbatim bytes of origin/main
// 31bb4be5, see SOURCE.txt) run beside the Go code on the same world. The head excerpt is the part of the script
// that S1 ports; the test appends the probe tail (the Go side has the same one), and stages the LIVE toolbelt/lib
// beside it so the sourced helpers stay under test too. A missing bash FAILS: a skipped differential proves
// nothing. The goldens are asserted equal to the oracle here and replayed through Go in the nodiff-visible tests.

var update = flag.Bool("update", false, "rewrite the goldens from the frozen oracle")

const (
	headSHA = "8d4482f0686616ab72c62da3ac1a3764f401f34462736b4c302939c07cf77545"
	liveLib = "../../../../toolbelt/lib"
)

var (
	stageOnce sync.Once
	stageDir  string
	stageErr  error
)

// seamMu serializes the Go runs that swap the package-level seams (the S5 differential swaps verifyState and the
// gh/reconcile seams), so its scenarios can run in parallel. S2-S4 swap no seam and take no lock.
var seamMu sync.Mutex

func TestMain(m *testing.M) {
	// The scenarios wait on the frozen bash script; t.Parallel() alone runs only GOMAXPROCS of them at once.
	parallelfloor.Raise(8)
	code := m.Run()
	for _, d := range []string{stageDir, s4Dir} {
		if d != "" {
			_ = os.RemoveAll(d)
		}
	}
	os.Exit(code)
}

func sha(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

func readFrozen(t testing.TB, name, want string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/legacy/" + name)
	must(t, err)
	if got := sha(b); got != want {
		t.Fatalf("frozen %s changed: sha256 %s, SOURCE.txt records %s", name, got, want)
	}
	return b
}

// stage returns <dir>/toolbelt with the head excerpt plus the probe tail and lib/ linked to the live library.
func stage(t testing.TB) string {
	t.Helper()
	stageOnce.Do(func() {
		stageDir, stageErr = os.MkdirTemp("", "status-show-diff-")
		if stageErr != nil {
			return
		}
		head := readFrozen(t, "status-head.sh", headSHA)
		tb := filepath.Join(stageDir, "toolbelt")
		if stageErr = os.MkdirAll(tb, 0o755); stageErr != nil {
			return
		}
		if stageErr = os.WriteFile(filepath.Join(tb, "research-sdd-status.sh"), append(head, probeTailBash...), 0o755); stageErr != nil {
			return
		}
		lib, err := filepath.Abs(liveLib)
		if err != nil {
			stageErr = err
			return
		}
		stageErr = os.Symlink(lib, filepath.Join(tb, "lib"))
	})
	if stageErr != nil {
		t.Fatalf("staging the oracle: %v", stageErr)
	}
	return filepath.Join(stageDir, "toolbelt")
}

func bashEnv(root string, extra map[string]string) []string {
	e := []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C", "HOME=" + root, "TMPDIR=" + root}
	for k, v := range extra {
		e = append(e, k+"="+v)
	}
	return e
}

func runBash(t testing.TB, sc scenario, root string) outcome {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join(stage(t), "research-sdd-status.sh")}, sc.argv(root)...)...)
	cmd.Dir = filepath.Join(root, sc.cwd)
	cmd.Env = bashEnv(root, sc.env)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("bash: %v", err)
		}
		rc = ee.ExitCode()
	}
	return outcome{rc, o.String(), e.String()}
}

// dropAwk removes the diagnostic lines of awk (an unreadable state file): Go reads the file itself.
func dropAwk(s string) string {
	var keep []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if !strings.HasPrefix(l, "awk:") {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "")
}

// checkGolden compares the scenario sections to the golden file, or rewrites it under -update.
func checkGolden(t *testing.T, path string, got map[string]string) {
	t.Helper()
	if *update {
		must(t, os.MkdirAll(filepath.Dir(path), 0o755))
		must(t, os.WriteFile(path, []byte(joinGolden(got)), 0o644))
		return
	}
	want := parseGolden(t, path)
	for n, g := range got {
		if want[n] != g {
			t.Errorf("golden %s differs from the oracle\nwant:\n%s\ngot:\n%s", n, want[n], g)
		}
	}
	for n := range want {
		if _, ok := got[n]; !ok {
			t.Errorf("golden section %s has no scenario", n)
		}
	}
}

func TestDifferentialArgsPick(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range argsPickScenarios() {
			t.Run(sc.name, func(t *testing.T) {
				skipIfRoot(t, sc)
				root := sc.build(t)
				goOut := runGo(t, sc, root)
				bashOut := runBash(t, sc, root)
				bashOut.err = dropAwk(bashOut.err)
				if goOut != bashOut {
					t.Errorf("differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
						goOut.rc, goOut.out, goOut.err, bashOut.rc, bashOut.out, bashOut.err)
				}
				mu.Lock()
				sections[sc.name] = render(sc.name, bashOut, root)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	// A skipped scenario (root user) has no oracle output: keep its golden section unchanged.
	for _, sc := range argsPickScenarios() {
		if _, ok := sections[sc.name]; !ok {
			if old, ok := parseGoldenIfPresent(t, goldenArgsPick)[sc.name]; ok && !*update {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenArgsPick, sections)
}

func parseGoldenIfPresent(t *testing.T, path string) map[string]string {
	if _, err := os.Stat(path); err != nil {
		return map[string]string{}
	}
	return parseGolden(t, path)
}

// probeTailBash is the same tail for the frozen excerpt, appended by the differential test.
const probeTailBash = `
if [ -n "${PROBE_SILENT:-}" ]; then exit 0; fi
if [ -n "${PROBE_VERDICT:-}" ]; then printf '%s\n' "$PROBE_VERDICT"; exit "${PROBE_RC:-0}"; fi
printf 'PICKED state=%s corpus=%s mode=%s focus=%s emit=%d all=%d queue=%d root=%d only=%s only_set=%d stall=%d\n' "$state" "$corpus" "$mode" "$focus_slug" "$emit_token" "$all_flag" "$queue_flag" "$root_flag" "$only_list" "$only_set" "$stall_minutes"
`

// joinGolden is the file written by -update: sections in name order.
func joinGolden(sections map[string]string) string {
	names := make([]string, 0, len(sections))
	for n := range sections {
		names = append(names, n)
	}
	sort.Strings(names)
	var b strings.Builder
	for _, n := range names {
		b.WriteString(sections[n])
	}
	return b.String()
}
