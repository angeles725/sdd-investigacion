//go:build unix && !nodiff

package show

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

// The is_blocked differential: the frozen blocked_names/is_blocked excerpt (testdata/legacy, see SOURCE.txt) runs
// over the LIVE lib/blocked-rows.sh, beside Go, on the same state files.

const blockedSHA = "d8dd62ccfe0d8441baabb06aa310f9d8163e4b681b56330d79456235cedb2cef"

// blockedHarness sources the live blocked-rows lib and the frozen is_blocked excerpt, then asks each gap in turn.
const blockedHarness = `state="$1"; shift
target=x
. "$BLOCKED_LIB"
blocked_body() { blocked_rows_body "$state"; }
. "$BLOCKED_EXCERPT"
i=0
for g in "$@"; do is_blocked "$g"; echo "gap$i -> $?"; i=$((i+1)); done
`

func runBlockedBash(t testing.TB, bs blockedScenario, root string) outcome {
	t.Helper()
	excerpt := readFrozen(t, "status-blocked.sh", blockedSHA)
	dir := t.TempDir()
	must(t, os.WriteFile(filepath.Join(dir, "excerpt.sh"), excerpt, 0o644))
	must(t, os.WriteFile(filepath.Join(dir, "harness.sh"), []byte(blockedHarness), 0o644))
	lib, err := filepath.Abs(liveLib)
	must(t, err)
	args := append([]string{filepath.Join(dir, "harness.sh"), filepath.Join(root, "RESEARCH-STATE.md")}, bs.gaps...)
	cmd := exec.Command("bash", args...)
	cmd.Dir = root
	cmd.Env = bashEnv(root, map[string]string{"BLOCKED_LIB": filepath.Join(lib, "blocked-rows.sh"), "BLOCKED_EXCERPT": filepath.Join(dir, "excerpt.sh")})
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	if err := cmd.Run(); err != nil {
		t.Fatalf("bash: %v\n%s", err, e.String())
	}
	return outcome{0, o.String(), dropAwk(e.String())}
}

func TestDifferentialIsBlocked(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	t.Run("scenarios", func(t *testing.T) {
		for _, bs := range blockedScenarios() {
			t.Run(bs.name, func(t *testing.T) {
				if bs.unreadable() && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				root := bs.build(t)
				goOut := runBlockedGo(t, bs, root)
				bashOut := runBlockedBash(t, bs, root)
				if goOut != bashOut {
					t.Errorf("differs from the frozen script\ngo:\n%s\nstderr:\n%s\nbash:\n%s\nstderr:\n%s", goOut.out, goOut.err, bashOut.out, bashOut.err)
				}
				mu.Lock()
				sections[bs.name] = render(bs.name, bashOut, root)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	for _, bs := range blockedScenarios() {
		if _, ok := sections[bs.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenIsBlocked)[bs.name]; ok {
				sections[bs.name] = old
			}
		}
	}
	checkGolden(t, goldenIsBlocked, sections)
}
