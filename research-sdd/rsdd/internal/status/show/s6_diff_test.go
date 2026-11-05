//go:build unix && !nodiff

package show

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
)

// The S6 differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, see SOURCE.txt) are put back
// together in the order of the original script and run as the real entry (`bash research-sdd-status.sh <target>
// ...`) over the LIVE toolbelt/lib. Nothing stands in for the S6 sections: the default report, the contradictions
// and iteration readers, saturation and the remote-visibility block are the script's own. The two S7 sections it
// calls (campaign_status_block and the document-cycle outline) are the authored stand-ins below, the same words as
// the Go seams of s6_harness_test.go. The subprocesses (gh, verify-state) are the authored fakes the port runs too.

// s6Frozen is the S5 order with the S6 excerpts at their places in the original script.
func s6Frozen() []struct{ file, sha string } {
	const (
		iterSHA = "461fd9686fd0bd4bb0d8a279f942e5524118ac0e40427c2ecb426d4eb5d9777b"
		satSHA  = "70f63fc30f70c86aaad0c96ce59d426ae754dc04796c7b79966859b6c1bfdcad"
		repSHA  = "bd5355cb0529033065ee444c2991b3df9342d9de291c56d66166b2179cee8f8c"
	)
	var out []struct{ file, sha string }
	for _, f := range s5Frozen {
		out = append(out, f)
		switch f.file {
		case "status-blocked-body.sh":
			out = append(out, struct{ file, sha string }{"status-iter.sh", iterSHA})
		case "status-cleanwarn.sh":
			out = append(out, struct{ file, sha string }{"status-saturation.sh", satSHA})
		}
	}
	return append(out, struct{ file, sha string }{"", ""}, struct{ file, sha string }{"status-report.sh", repSHA})
}

// s6MidBash stands in for lines 2046-2455 of the script (slice S7).
const s6MidBash = `
campaign_status_block() { printf '  %-16s: S6-STANDIN state=%s focus=%s\n' "campaign" "$(_rel_state "$state")" "${focus_slug:-}"; }
_doc_mode=0; _doc_noheading=0
case "${S6_DOC:-}" in outline) _doc_mode=1 ;; noheading) _doc_noheading=1 ;; esac
outline_summary() { :; }
outline_line() { echo "  outline         : S6-STANDIN"; }
outline_next_step() { echo "${S6_DOC_NEXT:-BOOTSTRAP | stand-in}"; }
`

// fakeVerifyS6 logs its argv and answers the spec: stdout, stderr, exit code.
const fakeVerifyS6 = `#!/usr/bin/env bash
d="$S5_LOG"; n=1; while [ -e "$d/ver.$n" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/ver.$n"
[ -f "$S5_SPEC/v.out" ] && cat "$S5_SPEC/v.out"
[ -f "$S5_SPEC/v.err" ] && cat "$S5_SPEC/v.err" >&2
exit "$(cat "$S5_SPEC/v.rc" 2>/dev/null || echo 0)"
`

// s6Stage writes <dir>/toolbelt (the assembled script, the fake verify-state, lib/ linked to the live library) and
// <dir>/bin (the fake gh), and builds the rsdd binary the live lib shims run (hook wiring). The directory is
// removed with the test that staged it.
func s6Stage(t *testing.T) (dir, rsddBin string) {
	t.Helper()
	dir, err := os.MkdirTemp("", "status-show-s6-")
	must(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	var script []byte
	for _, f := range s6Frozen() {
		if f.file == "" {
			script = append(script, s6MidBash...)
			continue
		}
		script = append(script, readFrozen(t, f.file, f.sha)...)
	}
	lib, err := filepath.Abs(liveLib)
	must(t, err)
	bin := filepath.Join(dir, "bin")
	must(t, os.MkdirAll(bin, 0o755))
	tb := filepath.Join(dir, "toolbelt")
	must(t, os.MkdirAll(tb, 0o755))
	must(t, os.Symlink(lib, filepath.Join(tb, "lib")))
	for p, body := range map[string]string{
		filepath.Join(tb, "research-sdd-status.sh"): string(script),
		filepath.Join(tb, "verify-state.sh"):        fakeVerifyS6,
		filepath.Join(bin, "gh"):                    fakeGH,
	} {
		must(t, os.WriteFile(p, []byte(body), 0o755))
	}
	if rsddBin = os.Getenv("RSDD_BIN"); rsddBin == "" {
		rsddBin = filepath.Join(dir, "rsdd")
		build := exec.Command("go", "build", "-o", rsddBin, "./cmd/rsdd")
		build.Dir = "../../.."
		if out, err := build.CombinedOutput(); err != nil {
			t.Fatalf("building rsdd: %v\n%s", err, out)
		}
	}
	return dir, rsddBin
}

// readS6Log reads the calls the fakes logged, in order.
func readS6Log(t testing.TB, dir, root string) s6Calls {
	t.Helper()
	k5, _ := readS5Log(t, dir, root)
	k := s6Calls{gh: k5.gh}
	for n := 1; ; n++ {
		b, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("ver.%d", n)))
		if err != nil {
			break
		}
		k.ver = append(k.ver, s5Calls{}.scrub(strings.Join(splitLines(string(b)), " "), root))
	}
	return k
}

func runBashS6(t testing.TB, sc s6Scenario, root, logDir, dir, rsddBin string) []outcome {
	t.Helper()
	var res []outcome
	for i := range sc.runs {
		cmd := exec.Command("bash", append([]string{filepath.Join(dir, "toolbelt", "research-sdd-status.sh")}, sc.argv(i, root)...)...)
		cmd.Dir = filepath.Join(root, sc.cwd)
		cmd.Env = append(sc.environ(root, logDir, filepath.Join(dir, "bin")), "RSDD_BIN="+rsddBin)
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

func TestDifferentialS6(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	dir, rsddBin := s6Stage(t)
	tb, bin := filepath.Join(dir, "toolbelt"), filepath.Join(dir, "bin")
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range s6Scenarios() {
			t.Run(sc.name, func(t *testing.T) {
				t.Parallel() // the frozen script runs concurrently; runGoS6 serializes the seam swaps
				if sc.needsUser && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				goRoot, bashRoot := sc.build(t), sc.build(t)
				goLog, bashLog := t.TempDir(), t.TempDir()
				goEnv := s5Env{append(sc.environ(goRoot, goLog, bin), "RSDD_BIN="+rsddBin), tb}
				goOuts := runGoS6(t, sc, goRoot, goEnv, nil)
				bashOuts := runBashS6(t, sc, bashRoot, bashLog, dir, rsddBin)
				for i := range sc.runs {
					want, got := render("", bashOuts[i], bashRoot), render("", goOuts[i], goRoot)
					if want != got {
						t.Errorf("run %d (%v) differs from the frozen script\nbash:\n%s\ngo:\n%s", i+1, sc.runs[i], want, got)
					}
				}
				if want, got := treeDump(t, bashRoot), treeDump(t, goRoot); stripRoot(want, bashRoot) != stripRoot(got, goRoot) {
					t.Errorf("the tree left behind differs from the frozen script\nbash:\n%s\ngo:\n%s", want, got)
				}
				bashCalls, goCalls := readS6Log(t, bashLog, bashRoot), readS6Log(t, goLog, goRoot)
				if !reflect.DeepEqual(bashCalls, goCalls) {
					t.Errorf("subprocess calls differ from the frozen script\nbash: %+v\ngo:   %+v", bashCalls, goCalls)
				}
				mu.Lock()
				sections[sc.name] = renderS6(t, sc, bashOuts, bashRoot, tb, bashCalls)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	// A skipped scenario (root user) has no oracle output: keep its golden section unchanged.
	for _, sc := range s6Scenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenS6)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenS6, sections)
}
