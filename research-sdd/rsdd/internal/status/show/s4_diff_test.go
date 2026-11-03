//go:build unix && !nodiff

package show

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// The S4 differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, see SOURCE.txt) are put back
// together in the order of the original script and run as the real entry (`bash research-sdd-status.sh <target>
// --next ...`) over the LIVE toolbelt/lib. The --next block is frozen in two halves with the S5 retro-coverage
// derivation (and issues_due_gate) replaced by the stand-ins of s4_harness_test.go between them.
//
// verify-state.sh, which the STALE gate runs, is staged as a wrapper over the real `rsdd verify state` (built from
// this module, or $RSDD_BIN), or over a fixed report for the scenarios that carry one. It logs every call, and the
// two sides, the script and the port (which runs the wrapper through its production exec), must make the same
// calls: the log of the script's side is what the golden records and the replay serves.

var s4Frozen = []struct{ file, sha string }{
	{"status-head.sh", headSHA},
	{"status-section.sh", "f8147b3058c98ef4c3a681bd17118c3bd28c78fb05728171c2c2648c0ba4295e"},
	{"status-blocked-body.sh", "7b79bef7a9157d5d22c87c965d5fbb837833d4b1e4e1b7baf68139acc6821dab"},
	{"status-blocked.sh", blockedSHA},
	{"status-derive.sh", "9b33b56be9240e59034d9da99fac463aa45723809f7fa7fd93b5ec18ad713c8d"},
	{"status-degraded.sh", "af27d52518a51f374882447d311b5c8f1bdc3e09dd1f1aa6888ff48c4232e24f"},
	{"status-scan.sh", "0ecc9f372f6887c5ba761f8cb1be8467e655ca5e39a16cf03d01e5d05773b243"},
	{"status-resolve.sh", "113ee0ac000aa3d340e0e50d88134edefa0049db8a256aad09a937328d61f68b"},
	{"status-counters.sh", "f99d0a0f98bf3933deb4330fd033e632d5589c633c8b1a4a4243232a1aededaa"},
	{"status-focuses.sh", "96fdab930a06add9a5b4a16bb8f6ae06c5f698b79ad89b8751175a328512b1eb"},
	{"status-bu.sh", "1af95128a84663368830907619e540ef896c31e902ab4c9c84fc1dffe1a81784"},
	{"status-next-a.sh", "4ce38fb337eb8235143e429a857b9123faf3787afdffc65015df5f57b7c9bc7a"},
	{"", ""}, // the stand-ins (s4MidBash)
	{"status-next-b.sh", "ea8f515e34b461d6021b880a032db482bda73141980aa42317f3317b0f457134"},
}

const verifyWrapper = `#!/usr/bin/env bash
d="$S4_VERIFY_LOG"; n=1; while [ -e "$d/$n.rc" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/$n.args"
if [ -n "${S4_FAKE_VERIFY+x}" ]; then printf '%s' "$S4_FAKE_VERIFY_OUT" > "$d/$n.out"; rc="${S4_FAKE_VERIFY_RC:-0}"
else "$S4_VERIFY_BIN" verify state "$@" > "$d/$n.out" 2>/dev/null; rc=$?; fi
cat "$d/$n.out"; echo "$rc" > "$d/$n.rc"; exit "$rc"
`

var (
	s4Once   sync.Once
	s4Script string
	s4Dir    string
	s4Bin    string
	s4Err    error
)

// s4Stage writes <dir>/toolbelt/research-sdd-status.sh (the assembled script) and verify-state.sh, with lib/ linked
// to the live library, and builds the rsdd binary the wrapper runs.
func s4Stage(t testing.TB) string {
	t.Helper()
	s4Once.Do(func() {
		s4Dir, s4Err = os.MkdirTemp("", "status-show-s4-")
		if s4Err != nil {
			return
		}
		var script []byte
		for _, f := range s4Frozen {
			if f.file == "" {
				script = append(script, s4MidBash...)
				continue
			}
			script = append(script, readFrozen(t, f.file, f.sha)...)
		}
		script = append(script, s4TailBash...)
		tb := filepath.Join(s4Dir, "toolbelt")
		if s4Err = os.MkdirAll(tb, 0o755); s4Err != nil {
			return
		}
		s4Script = filepath.Join(tb, "research-sdd-status.sh")
		if s4Err = os.WriteFile(s4Script, script, 0o755); s4Err != nil {
			return
		}
		if s4Err = os.WriteFile(filepath.Join(tb, "verify-state.sh"), []byte(verifyWrapper), 0o755); s4Err != nil {
			return
		}
		lib, err := filepath.Abs(liveLib)
		if err != nil {
			s4Err = err
			return
		}
		if s4Err = os.Symlink(lib, filepath.Join(tb, "lib")); s4Err != nil {
			return
		}
		if s4Bin = os.Getenv("RSDD_BIN"); s4Bin == "" {
			s4Bin = filepath.Join(s4Dir, "rsdd")
			build := exec.Command("go", "build", "-o", s4Bin, "./cmd/rsdd")
			build.Dir = "../../.."
			if out, err := build.CombinedOutput(); err != nil {
				s4Err = fmt.Errorf("building rsdd: %v\n%s", err, out)
			}
		}
	})
	if s4Err != nil {
		t.Fatalf("staging the S4 oracle: %v", s4Err)
	}
	return s4Script
}

// verifyEnv is the extra environment of one run: where verify-state logs, what it runs, or the fixed report.
func (sc s4Scenario) verifyEnv(logDir string) map[string]string {
	extra := map[string]string{"S4_VERIFY_LOG": logDir, "S4_VERIFY_BIN": s4Bin}
	if sc.fake != nil {
		extra["S4_FAKE_VERIFY"] = "1"
		extra["S4_FAKE_VERIFY_OUT"] = sc.fake.out
		extra["S4_FAKE_VERIFY_RC"] = strconv.Itoa(sc.fake.rc)
	}
	return extra
}

// readVerifyLog reads the calls the wrapper logged, in order, with the world root written <ROOT>.
func readVerifyLog(t testing.TB, dir, root string) []verifyCall {
	t.Helper()
	scrub := func(s string) string { return strings.ReplaceAll(s, root, "<ROOT>") }
	var calls []verifyCall
	for n := 1; ; n++ {
		rcb, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%d.rc", n)))
		if err != nil {
			return calls
		}
		args, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%d.args", n)))
		must(t, err)
		out, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%d.out", n)))
		must(t, err)
		rc, err := strconv.Atoi(strings.TrimSpace(string(rcb)))
		must(t, err)
		var av []string
		for _, a := range splitLines(string(args)) {
			av = append(av, scrub(a))
		}
		calls = append(calls, verifyCall{av, scrub(string(out)), rc})
	}
}

func runBashS4(t testing.TB, sc s4Scenario, root, logDir string) []outcome {
	t.Helper()
	script := s4Stage(t)
	var res []outcome
	for i := range sc.runs {
		cmd := exec.Command("bash", append([]string{script}, sc.argv(i, root)...)...)
		cmd.Dir = filepath.Join(root, sc.cwd)
		cmd.Env = bashEnv(root, sc.verifyEnv(logDir))
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

// goEnv is the port's side: the production exec of the staged verify-state.sh, with the environment bash had.
func goEnv(sc s4Scenario, root, logDir string) s4Env {
	tb := filepath.Join(s4Dir, "toolbelt")
	return s4Env{
		env: func(k string) string {
			if k == "RSDD_TOOLBELT_DIR" {
				return tb
			}
			return ""
		},
		environ: func() []string { return bashEnv(root, sc.verifyEnv(logDir)) },
	}
}

func TestDifferentialS4(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	s4Stage(t)
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range s4Scenarios() {
			t.Run(sc.name, func(t *testing.T) {
				if sc.needsUser && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				goRoot, bashRoot := sc.build(t), sc.build(t)
				goLog, bashLog := t.TempDir(), t.TempDir()
				goOuts := runGoS4(t, sc, goRoot, goEnv(sc, goRoot, goLog))
				bashOuts := runBashS4(t, sc, bashRoot, bashLog)
				for i := range sc.runs {
					want, got := render("", bashOuts[i], bashRoot), render("", goOuts[i], goRoot)
					if want != got {
						t.Errorf("run %d (%v) differs from the frozen script\nbash:\n%s\ngo:\n%s", i+1, sc.runs[i], want, got)
					}
				}
				if want, got := treeDump(t, bashRoot), treeDump(t, goRoot); stripRoot(want, bashRoot) != stripRoot(got, goRoot) {
					t.Errorf("the tree left behind differs from the frozen script\nbash:\n%s\ngo:\n%s", want, got)
				}
				bashCalls, goCalls := readVerifyLog(t, bashLog, bashRoot), readVerifyLog(t, goLog, goRoot)
				if !reflect.DeepEqual(bashCalls, goCalls) {
					t.Errorf("verify-state calls differ from the frozen script\nbash: %+v\ngo:   %+v", bashCalls, goCalls)
				}
				mu.Lock()
				sections[sc.name] = renderS4(t, sc, bashOuts, bashRoot, bashCalls)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	// A skipped scenario (root user) has no oracle output: keep its golden section unchanged.
	for _, sc := range s4Scenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenS4)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenS4, sections)
}
