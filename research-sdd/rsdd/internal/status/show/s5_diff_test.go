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

// The S5 differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, see SOURCE.txt) are put back
// together in the order of the original script, and run as the real entry (`bash research-sdd-status.sh <target>
// --next ...`) over the LIVE toolbelt/lib. Unlike S4, nothing stands in for the S5 sections: the retro-coverage
// derivation, issues_due_gate and the terminal clean-check are the script's own. The subprocesses they start are the
// authored fakes of s5_harness_test.go, which the port runs too (reconcile through the production runner with the
// fake as the command).

var s5Frozen = []struct{ file, sha string }{
	{"status-head.sh", headSHA},
	{"status-section.sh", "f8147b3058c98ef4c3a681bd17118c3bd28c78fb05728171c2c2648c0ba4295e"},
	{"status-blocked-body.sh", "7b79bef7a9157d5d22c87c965d5fbb837833d4b1e4e1b7baf68139acc6821dab"},
	{"status-cleanwarn.sh", "7fcf29133c3586887e569f2f5ad81aff5faadfafff9b2c30198a4e20fecdb082"},
	{"status-blocked.sh", blockedSHA},
	{"status-derive.sh", "9b33b56be9240e59034d9da99fac463aa45723809f7fa7fd93b5ec18ad713c8d"},
	{"status-degraded.sh", "af27d52518a51f374882447d311b5c8f1bdc3e09dd1f1aa6888ff48c4232e24f"},
	{"status-scan.sh", "0ecc9f372f6887c5ba761f8cb1be8467e655ca5e39a16cf03d01e5d05773b243"},
	{"status-resolve.sh", "113ee0ac000aa3d340e0e50d88134edefa0049db8a256aad09a937328d61f68b"},
	{"status-counters.sh", "f99d0a0f98bf3933deb4330fd033e632d5589c633c8b1a4a4243232a1aededaa"},
	{"status-focuses.sh", "96fdab930a06add9a5b4a16bb8f6ae06c5f698b79ad89b8751175a328512b1eb"},
	{"status-bu.sh", "1af95128a84663368830907619e540ef896c31e902ab4c9c84fc1dffe1a81784"},
	{"status-idg.sh", "c865ce1278fcb03bfb7e7c1c873b6873297bfe7cd0c92a15596ef54fc25e597e"},
	{"status-next-a.sh", "4ce38fb337eb8235143e429a857b9123faf3787afdffc65015df5f57b7c9bc7a"},
	{"status-covers.sh", "6b8344b83111c2bb03cf352c487216bbfd14564bd52d55fa026275a798cfc7cc"},
	{"status-next-b.sh", "ea8f515e34b461d6021b880a032db482bda73141980aa42317f3317b0f457134"},
}

// ---- the fakes -------------------------------------------------------------------------------------------

const (
	fakeGH = `#!/usr/bin/env bash
d="$S5_LOG"; n=1; while [ -e "$d/gh.$n" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/gh.$n"
[ -f "$S5_SPEC/gh.sleep" ] && exec sleep "$(cat "$S5_SPEC/gh.sleep")"
[ -f "$S5_SPEC/gh.out" ] && cat "$S5_SPEC/gh.out"
[ -f "$S5_SPEC/gh.err" ] && cat "$S5_SPEC/gh.err" >&2
exit "$(cat "$S5_SPEC/gh.rc" 2>/dev/null || echo 0)"
`
	fakeReconcile = `#!/usr/bin/env bash
d="$S5_LOG"; n=1; while [ -e "$d/rec.$n.args" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/rec.$n.args"
cache=""; retro=""
while [ $# -gt 0 ]; do case "$1" in --issues-cache) cache="$2"; shift 2;; *) retro="$1"; shift;; esac; done
key="$(basename "$retro")"
if [ -n "$cache" ]; then key="$key.c"; cp "$cache" "$d/rec.$n.cache"; fi
s="$S5_SPEC/r.$key"
[ -f "$s.sleep" ] && sleep "$(cat "$s.sleep")"
[ -f "$s.out" ] && cat "$s.out"
[ -f "$s.err" ] && cat "$s.err" >&2
exit "$(cat "$s.rc" 2>/dev/null || echo 0)"
`
	fakeCleanCheck = `#!/usr/bin/env bash
d="$S5_LOG"; n=1; while [ -e "$d/cc.$n" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/cc.$n"
[ -f "$S5_SPEC/cc.sleep" ] && sleep "$(cat "$S5_SPEC/cc.sleep")"
[ -f "$S5_SPEC/cc.out" ] && cat "$S5_SPEC/cc.out"
exit "$(cat "$S5_SPEC/cc.rc" 2>/dev/null || echo 0)"
`
	fakeVerifyScript = "#!/usr/bin/env bash\nexit 0\n"
	// fakeGit must never run: the gate is read-only and starts no git network subcommand (nor any git).
	fakeGit = `#!/usr/bin/env bash
d="$S5_LOG"; n=1; while [ -e "$d/git.$n" ]; do n=$((n+1)); done
printf '%s\n' "$@" > "$d/git.$n"
exit 99
`
)

// readS5Log reads the calls the fakes logged, in order.
func readS5Log(t testing.TB, dir, root string) (k s5Calls, extra []string) {
	t.Helper()
	read := func(name string) (string, bool) {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return "", false
		}
		return string(b), true
	}
	argv := func(s string) string { return k.scrub(strings.Join(splitLines(s), " "), root) }
	for n := 1; ; n++ {
		s, ok := read(fmt.Sprintf("gh.%d", n))
		if !ok {
			break
		}
		k.gh = append(k.gh, argv(s))
	}
	for n := 1; ; n++ {
		s, ok := read(fmt.Sprintf("rec.%d.args", n))
		if !ok {
			break
		}
		line := argv(s)
		if c, ok := read(fmt.Sprintf("rec.%d.cache", n)); ok {
			line += " | cache=" + strconv.Quote(c)
		}
		k.rec = append(k.rec, line)
	}
	for n := 1; ; n++ {
		s, ok := read(fmt.Sprintf("cc.%d", n))
		if !ok {
			break
		}
		k.cc = append(k.cc, argv(s))
	}
	for n := 1; ; n++ {
		s, ok := read(fmt.Sprintf("git.%d", n))
		if !ok {
			break
		}
		extra = append(extra, argv(s))
	}
	return k, extra
}

var (
	s5Once sync.Once
	s5Dir  string
	s5Err  error
)

// s5Stage writes <dir>/toolbelt (the assembled script, the fakes, lib/ linked to the live library) and <dir>/bin
// (the fake gh and git), once.
func s5Stage(t testing.TB) string {
	t.Helper()
	s5Once.Do(func() {
		if s5Dir, s5Err = os.MkdirTemp("", "status-show-s5-"); s5Err != nil {
			return
		}
		var script []byte
		for _, f := range s5Frozen {
			script = append(script, readFrozen(t, f.file, f.sha)...)
		}
		script = append(script, s4TailBash...)
		bin := filepath.Join(s5Dir, "bin")
		lib, err := filepath.Abs(liveLib)
		if err != nil {
			s5Err = err
			return
		}
		must(t, os.MkdirAll(bin, 0o755))
		for name, withCC := range map[string]bool{"toolbelt": true, "toolbelt-nocc": false} {
			tb := filepath.Join(s5Dir, name)
			must(t, os.MkdirAll(tb, 0o755))
			must(t, os.Symlink(lib, filepath.Join(tb, "lib")))
			fakes := map[string]string{
				filepath.Join(tb, "research-sdd-status.sh"): string(script),
				filepath.Join(tb, "verify-state.sh"):        fakeVerifyScript,
				filepath.Join(tb, "reconcile-issues.sh"):    fakeReconcile,
			}
			if withCC {
				fakes[filepath.Join(tb, "clean-check.sh")] = fakeCleanCheck
			}
			for p, body := range fakes {
				must(t, os.WriteFile(p, []byte(body), 0o755))
			}
		}
		for name, body := range map[string]string{"gh": fakeGH, "git": fakeGit} {
			must(t, os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755))
		}
	})
	if s5Err != nil {
		t.Fatalf("staging the S5 oracle: %v", s5Err)
	}
	return s5Dir
}

func runBashS5(t testing.TB, sc s5Scenario, root, logDir string) []outcome {
	t.Helper()
	dir := s5Stage(t)
	var res []outcome
	for i := range sc.runs {
		cmd := exec.Command("bash", append([]string{filepath.Join(dir, sc.toolbeltName(), "research-sdd-status.sh")}, sc.argv(i, root)...)...)
		cmd.Dir = filepath.Join(root, sc.cwd)
		cmd.Env = sc.environ(root, logDir, filepath.Join(dir, "bin"))
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

func TestDifferentialS5(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	dir := s5Stage(t)
	bin := filepath.Join(dir, "bin")
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range s5Scenarios() {
			t.Run(sc.name, func(t *testing.T) {
				t.Parallel() // the frozen script runs concurrently; runGoS5 serializes the seam swaps
				if sc.needsUser && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				tb := filepath.Join(dir, sc.toolbeltName())
				goRoot, bashRoot := sc.build(t), sc.build(t)
				goLog, bashLog := t.TempDir(), t.TempDir()
				goOuts := runGoS5(t, sc, goRoot, s5Env{sc.environ(goRoot, goLog, bin), tb}, s5Drive{reconcileFake: filepath.Join(tb, "reconcile-issues.sh")})
				bashOuts := runBashS5(t, sc, bashRoot, bashLog)
				for i := range sc.runs {
					want, got := render("", bashOuts[i], bashRoot), render("", goOuts[i], goRoot)
					if want != got {
						t.Errorf("run %d (%v) differs from the frozen script\nbash:\n%s\ngo:\n%s", i+1, sc.runs[i], want, got)
					}
				}
				if want, got := treeDump(t, bashRoot), treeDump(t, goRoot); stripRoot(want, bashRoot) != stripRoot(got, goRoot) {
					t.Errorf("the tree left behind differs from the frozen script\nbash:\n%s\ngo:\n%s", want, got)
				}
				bashCalls, bashExtra := readS5Log(t, bashLog, bashRoot)
				goCalls, goExtra := readS5Log(t, goLog, goRoot)
				if !reflect.DeepEqual(bashCalls, goCalls) {
					t.Errorf("subprocess calls differ from the frozen script\nbash: %+v\ngo:   %+v", bashCalls, goCalls)
				}
				if len(bashExtra)+len(goExtra) != 0 {
					t.Errorf("git ran: bash %v, go %v (the gate is read-only: no git subcommand, network or not)", bashExtra, goExtra)
				}
				mu.Lock()
				sections[sc.name] = renderS5(t, sc, bashOuts, bashRoot, bashCalls)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	// A skipped scenario (root user) has no oracle output: keep its golden section unchanged.
	for _, sc := range s5Scenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenS5)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenS5, sections)
}

// toolbeltName is the staged toolbelt directory the scenario runs in.
func (sc s5Scenario) toolbeltName() string {
	if sc.noCC {
		return "toolbelt-nocc"
	}
	return "toolbelt"
}
