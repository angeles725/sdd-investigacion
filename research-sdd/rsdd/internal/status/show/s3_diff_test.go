//go:build unix && !nodiff

package show

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// The S3 differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, see SOURCE.txt) are put back
// together in the order of the original script and run as the real entry (`bash research-sdd-status.sh <target>
// --sync-state ...`) over the LIVE toolbelt/lib. The pieces of the script that are not ported yet are absent; the
// authored tail answers every mode other than --sync-state with the line the Go test tail prints.

var s3Frozen = []struct{ file, sha string }{
	{"status-head.sh", headSHA},
	{"status-section.sh", "f8147b3058c98ef4c3a681bd17118c3bd28c78fb05728171c2c2648c0ba4295e"},
	{"status-blocked-body.sh", "7b79bef7a9157d5d22c87c965d5fbb837833d4b1e4e1b7baf68139acc6821dab"},
	{"status-blocked.sh", blockedSHA},
	{"status-derive.sh", "9b33b56be9240e59034d9da99fac463aa45723809f7fa7fd93b5ec18ad713c8d"},
	{"status-scan.sh", "0ecc9f372f6887c5ba761f8cb1be8467e655ca5e39a16cf03d01e5d05773b243"},
	{"status-counters.sh", "f99d0a0f98bf3933deb4330fd033e632d5589c633c8b1a4a4243232a1aededaa"},
	{"status-focuses.sh", "96fdab930a06add9a5b4a16bb8f6ae06c5f698b79ad89b8751175a328512b1eb"},
	{"status-sync.sh", "eb75cf6f81131180bc516f8c2a451a7dff86c0f8fd14155072a25e0433d6bd64"},
}

var (
	s3Once   sync.Once
	s3Script string
	s3Dir    string
	s3Err    error
)

// s3Stage writes <dir>/toolbelt/research-sdd-status.sh (the assembled script) with lib/ linked to the live library.
func s3Stage(t testing.TB) string {
	t.Helper()
	s3Once.Do(func() {
		s3Dir, s3Err = os.MkdirTemp("", "status-show-s3-")
		if s3Err != nil {
			return
		}
		var script []byte
		for _, f := range s3Frozen {
			script = append(script, readFrozen(t, f.file, f.sha)...)
		}
		script = append(script, s3TailBash...)
		tb := filepath.Join(s3Dir, "toolbelt")
		if s3Err = os.MkdirAll(tb, 0o755); s3Err != nil {
			return
		}
		s3Script = filepath.Join(tb, "research-sdd-status.sh")
		if s3Err = os.WriteFile(s3Script, script, 0o755); s3Err != nil {
			return
		}
		lib, err := filepath.Abs(liveLib)
		if err != nil {
			s3Err = err
			return
		}
		s3Err = os.Symlink(lib, filepath.Join(tb, "lib"))
	})
	if s3Err != nil {
		t.Fatalf("staging the S3 oracle: %v", s3Err)
	}
	return s3Script
}

func runBashS3(t testing.TB, sc s3Scenario, root string) []outcome {
	t.Helper()
	script := s3Stage(t)
	var res []outcome
	for i := range sc.runs {
		cmd := exec.Command("bash", append([]string{script}, sc.argv(i, root)...)...)
		cmd.Dir = filepath.Join(root, sc.cwd)
		cmd.Env = bashEnv(root, nil)
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
		res = append(res, outcome{rc, o.String(), dropAwk(e.String())})
	}
	return res
}

func TestDifferentialS3(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range s3Scenarios() {
			t.Run(sc.name, func(t *testing.T) {
				if sc.needsUser && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				// Each side gets its own copy of the world: the sync rewrites it.
				goRoot, bashRoot := sc.build(t), sc.build(t)
				goOuts := runGoS3(t, sc, goRoot)
				bashOuts := runBashS3(t, sc, bashRoot)
				for i := range sc.runs {
					want, got := render("", bashOuts[i], bashRoot), render("", goOuts[i], goRoot)
					if want != got {
						t.Errorf("run %d (%v) differs from the frozen script\nbash:\n%s\ngo:\n%s", i+1, sc.runs[i], want, got)
					}
				}
				if want, got := treeDump(t, bashRoot), treeDump(t, goRoot); stripRoot(want, bashRoot) != stripRoot(got, goRoot) {
					t.Errorf("the tree left behind differs from the frozen script\nbash:\n%s\ngo:\n%s", want, got)
				}
				mu.Lock()
				sections[sc.name] = renderS3(t, sc, bashOuts, bashRoot)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	// A skipped scenario (root user) has no oracle output: keep its golden section unchanged.
	for _, sc := range s3Scenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenS3)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenS3, sections)
}

func stripRoot(s, root string) string { return strings.ReplaceAll(s, root, "<ROOT>") }
