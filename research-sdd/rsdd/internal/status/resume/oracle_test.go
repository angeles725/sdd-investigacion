//go:build !nodiff

package resume

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Everything that runs the frozen scripts lives in this file, excluded from the nodiff build (`make teeth`): a mutant
// must not re-run bash. The Go side is replayed against the goldens by golden_test.go, so the kills do not depend on it.

// The pinned oracle: testdata/legacy holds the scripts as of the port (kit issue #2578); see SOURCE.txt. A changed
// oracle must be a deliberate, reviewed edit of these constants.
const (
	legacyStateSHA  = "552aead4b47bad0054928d23b8d7bb5e860c15ee0e70a7725706535202d55aa7"
	legacyRenderSHA = "30daa171fa444563e3866cba35ca14cc112ca4d6215dd856f9096caa91bc4340"
)

const legacyRel = "testdata/legacy"

var updateGoldens = flag.Bool("update-resume", false, "re-record the goldens from the frozen scripts")

func fileSHA(t testing.TB, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func TestLegacyOraclePinned(t *testing.T) {
	for name, want := range map[string]string{"resume-state.sh": legacyStateSHA, "resume-render.sh": legacyRenderSHA} {
		if got := fileSHA(t, filepath.Join(legacyRel, name)); got != want {
			t.Errorf("%s sha256 = %s, want %s: the frozen oracle changed", name, got, want)
		}
	}
}

func legacyAbs(t testing.TB) string {
	t.Helper()
	d, err := filepath.Abs(legacyRel)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// runLegacy runs the frozen script of the scenario's command.
func runLegacy(t testing.TB, sc scn) outcome {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	w := getWorld(t, sc.world0())
	cwd := sc.prepare(t, w)
	script := filepath.Join(legacyAbs(t), "resume-state.sh")
	if sc.cmd == "resume-render" {
		script = filepath.Join(legacyAbs(t), "resume-render.sh")
	}
	c := exec.Command(bash, append([]string{script}, sc.argv(w)...)...)
	c.Dir, c.Env = cwd, sc.environ(t, w)
	c.Stdin = strings.NewReader(sc.stdin)
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	rc := 0
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatal(err)
		}
		rc = ee.ExitCode()
	}
	return outcome{rc, out.String(), errb.String()}
}

func TestDifferential(t *testing.T) {
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			want := scrubbed(t, sc, runLegacy(t, sc))
			if got := scrubbed(t, sc, runGo(t, sc)); got != want {
				t.Errorf("Go differs from the frozen script\n--- bash\n%s\n--- go\n%s", goldenText(want), goldenText(got))
			}
			if sc.toolbl {
				if got := scrubbed(t, sc, runGo(t, sc, "--toolbelt", legacyAbs(t))); got != want {
					t.Errorf("Go with the frozen sibling differs\n--- bash\n%s\n--- go\n%s", goldenText(want), goldenText(got))
				}
			}
		})
	}
}

// TestUpdateGoldens re-records every golden from the frozen scripts: go test -run TestUpdateGoldens -update-resume.
func TestUpdateGoldens(t *testing.T) {
	if !*updateGoldens {
		t.Skip("pass -update-resume to re-record the goldens")
	}
	if err := os.MkdirAll(goldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	keep := map[string]bool{}
	for _, sc := range scenarios() {
		keep[sc.name+".golden"] = true
		o := scrubbed(t, sc, runLegacy(t, sc))
		if err := os.WriteFile(goldenPath(sc.name), []byte(goldenText(o)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	entries, _ := os.ReadDir(goldenDir)
	for _, e := range entries {
		if !keep[e.Name()] {
			_ = os.Remove(filepath.Join(goldenDir, e.Name()))
		}
	}
}
