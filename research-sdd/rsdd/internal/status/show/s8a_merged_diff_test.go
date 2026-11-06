//go:build unix && !nodiff

package show

import (
	"bytes"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// RC-GOLDEN-3 (main suite 3537): the MERGED stream (`2>&1`) of a degraded run keeps the script's interleaving of
// stdout and stderr. The differentials compare the two streams separately; this one writes both to ONE buffer, on
// both sides, over a world that writes to stderr (two contradiction ledgers) and to stdout (a failing gh).
func TestS8aMergedStreamOrderMatchesTheScript(t *testing.T) {
	ledger := contraLedger("| C1 | a | b | open | n |")
	sc := os6("s8a-L3537-rc-golden-3-merged-order", "degraded: remote-visibility: gh failed", st6(1, "", row("high", "H1", "pending")),
		merge(gitRepo("origin", "https://github.com/o/r.git"), spec("gh.out", "", "gh.rc", "1"), files{"corpus/CONTRADICTIONS.md": ledger, "corpus/CONTRADICTIONS-b.md": ledger}), nil)
	dir, rsddBin := s6Stage(t)
	tb, bin := filepath.Join(dir, "toolbelt"), filepath.Join(dir, "bin")

	bashRoot, goRoot := sc.build(t), sc.build(t)
	var bm bytes.Buffer
	cmd := exec.Command("bash", append([]string{filepath.Join(tb, "research-sdd-status.sh")}, sc.argv(0, bashRoot)...)...)
	cmd.Dir = bashRoot
	cmd.Env = append(sc.environ(bashRoot, t.TempDir(), bin), "RSDD_BIN="+rsddBin)
	cmd.Stdout, cmd.Stderr = &bm, &bm
	if err := cmd.Run(); err != nil {
		t.Fatalf("bash: %v", err)
	}

	var gm bytes.Buffer
	goEnv := s5Env{append(sc.environ(goRoot, t.TempDir(), bin), "RSDD_BIN="+rsddBin), tb}
	seamMu.Lock()
	s := cli.Stdio{In: strings.NewReader(""), Out: &gm, Err: &gm, Env: goEnv.lookup, Environ: func() []string { return goEnv.environ },
		Clock: func() time.Time { return time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: goRoot}
	run(sc.argv(0, goRoot), s, syncOr(nextOr(liveSeams, (*ctx).report)))
	seamMu.Unlock()

	want, got := strings.ReplaceAll(bm.String(), bashRoot, "<ROOT>"), strings.ReplaceAll(gm.String(), goRoot, "<ROOT>")
	if !strings.Contains(want, "WARN: multiple CONTRADICTIONS") || !strings.Contains(want, "degraded: remote-visibility: gh failed") {
		t.Fatalf("the fixture does not write both streams:\n%s", want)
	}
	if want != got {
		t.Errorf("merged 2>&1 order differs from the script\nbash:\n%s\ngo:\n%s", want, got)
	}
}
