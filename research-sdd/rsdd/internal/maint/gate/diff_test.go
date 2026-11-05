//go:build !nodiff

package gate

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// The differential test: every scenario runs against the frozen legacy kit-gate.sh (testdata/legacy) and against
// run, each in a fresh identical world, and the two must agree on exit code, stdout, stderr, the ordered call log and
// the state directory left behind. Declared divergences, each pinned by its own Go test:
//   - the `DEGRADED: ...` stderr line of an exit 3 (rsdd process contract);
//   - the bash called the flock binary (`flock -w N 9` in the call log), Go locks in process: the line is dropped
//     from the legacy log; a lock that cannot be taken is therefore tested in Go (TestLockTimeoutIsTypedNotAGateFailure);
//   - git runs as `git -C <worktree> ...` instead of after a cd: the `-C <dir>` is dropped from the Go log.
var (
	degradedLine = regexp.MustCompile(`(?m)^DEGRADED: .*\n?`)
	flockCall    = regexp.MustCompile(`(?m)^flock -w [0-9]+ 9\n?`)
	gitDirFlag   = regexp.MustCompile(`(?m)^git -C \S+ `)
)

type gateScenario struct {
	name  string
	setup func(t *testing.T, w *kitworld.World) (args []string, env []string)
	want  int // exit code both sides must give
}

func args(a ...string) []string { return a }

func plain(a ...string) func(*testing.T, *kitworld.World) ([]string, []string) {
	return func(t *testing.T, w *kitworld.World) ([]string, []string) {
		headRule(w)
		runAll(t, w)
		out := make([]string, len(a))
		for i, x := range a {
			x = strings.ReplaceAll(x, "@WT@", w.Wt)
			x = strings.ReplaceAll(x, "@W@", w.Dir)
			out[i] = x
		}
		return out, nil
	}
}

func gateScenarios() []gateScenario {
	st := "@W@/st"
	return []gateScenario{
		{"pass", plain("--state-dir", st, "--cmd", `echo "AGGREGATE RESULT: 3 passed"`, "@WT@", "lbl"), 0},
		{"fail7", plain("--state-dir", st, "--cmd", `echo GATE-RAN >> "$SHIM_STATE/calls.log"; echo "AGGREGATE RESULT: 3 passed"; exit 7`, "@WT@", "lbl"), 16},
		{"overflow", plain("--state-dir", st, "--cmd", `i=1; while [ $i -le 20 ]; do echo "passed $i"; echo "other $i"; i=$((i+1)); done`, "@WT@", "lbl"), 0},
		{"keywords", plain("--state-dir", st, "--cmd", `echo "FAIL  a"; echo "x leftovers y"; echo "hermeticity"; echo "Suites"; echo "nothing"; echo "FAIL b"`, "@WT@", "lbl"), 0},
		{"serial", plain("--state-dir", st, "--serial", "@WT@", "lbl"), 0},
		{"default", plain("--state-dir", st, "@WT@", "lbl"), 0},
		{"emptycmd", plain("--state-dir", st, "--cmd", "", "@WT@", "lbl"), 0},
		{"dashdash", plain("--state-dir", st, "--cmd", "true", "--", "@WT@", "lbl"), 0},
		{"serialcmd", plain("--state-dir", st, "--serial", "--cmd", "true", "@WT@", "lbl"), 2},
		{"noargs", plain(), 2},
		{"onearg", plain("@WT@"), 2},
		{"threeargs", plain("@WT@", "l", "x"), 2},
		{"unknown", plain("--bogus", "@WT@", "lbl"), 2},
		{"cmdnovalue", plain("--cmd"), 2},
		{"locknovalue", plain("--lock-timeout"), 2},
		{"statenovalue", plain("--state-dir"), 2},
		{"badlabel", plain("--state-dir", st, "@WT@", "a/b"), 2},
		{"emptylabel", plain("--state-dir", st, "@WT@", ""), 2},
		{"badlock", plain("--state-dir", st, "--lock-timeout", "1s", "@WT@", "lbl"), 2},
		{"emptylock", plain("--state-dir", st, "--lock-timeout", "", "@WT@", "lbl"), 2},
		{"lockzero", plain("--state-dir", st, "--lock-timeout", "0", "--cmd", "true", "@WT@", "lbl"), 0},
		{"nowt", plain("--state-dir", st, "--cmd", "true", "@W@/nope", "lbl"), 2},
		{"stateinwt", plain("--state-dir", "@WT@/state", "--cmd", "true", "@WT@", "lbl"), 2},
		{"statelink", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			headRule(w)
			if err := os.MkdirAll(w.Wt+"/sub", 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(w.Wt+"/sub", w.Dir+"/lnk"); err != nil {
				t.Fatal(err)
			}
			return args("--state-dir", w.Dir+"/lnk/state", "--cmd", "true", w.Wt, "lbl"), nil
		}, 2},
		{"relativestate", plain("--state-dir", "rel/state", "--cmd", "true", "@WT@", "lbl"), 2},
		{"xdg", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			headRule(w)
			return args("--cmd", "true", w.Wt, "lbl"), []string{"XDG_STATE_HOME=" + w.Dir + "/xdg"}
		}, 0},
		{"home", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			headRule(w)
			return args("--cmd", "true", w.Wt, "lbl"), []string{"XDG_STATE_HOME="}
		}, 0},
		{"noflock", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			w.Drop("flock")
			return args("--state-dir", w.Dir+"/st", "--cmd", "true", w.Wt, "lbl"), nil
		}, 3},
		{"nogit", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			w.Drop("git")
			return args("--state-dir", w.Dir+"/st", "--cmd", "true", w.Wt, "lbl"), nil
		}, 3},
		{"noboth", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			w.Drop("git")
			w.Drop("flock")
			return args("--state-dir", w.Dir+"/st", "--cmd", "true", w.Wt, "lbl"), nil
		}, 3},
		{"help", plain("--help"), 0},
		{"helpshort", plain("--serial", "-h", "--bogus"), 0},
		{"helpafterbad", plain("--bogus", "-h"), 2},
		{"envlock", func(t *testing.T, w *kitworld.World) ([]string, []string) {
			headRule(w)
			return args("--state-dir", w.Dir+"/st", "--cmd", "true", w.Wt, "lbl"), []string{"KIT_GATE_LOCK_TIMEOUT=abc"}
		}, 2},
	}
}

// world snapshot: the state directory tree (relative names, file contents) and the normalised call log.
func snapshot(w *kitworld.World) string {
	var lines []string
	for _, root := range []string{w.Dir + "/st", w.Dir + "/xdg", w.Dir + "/.local", w.Wt + "/rel", w.Wt + "/state", w.Wt + "/sub"} {
		_ = filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
			if err != nil || p == root && !fi.IsDir() {
				return nil
			}
			rel := strings.TrimPrefix(p, w.Dir)
			if fi.IsDir() {
				lines = append(lines, "dir "+rel)
				return nil
			}
			b, _ := os.ReadFile(p)
			lines = append(lines, "file "+rel+" ["+w.Norm(string(b))+"]")
			return nil
		})
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

func TestGateDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "kit-gate.sh", "kit-maint-common.sh")
	for _, sc := range gateScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			wb := kitworld.New(t)
			bargs, benv := sc.setup(t, wb)
			legacy := kitworld.RunBash(t, wb.Wt, wb.Env(benv...), stage+"/kit-gate.sh", bargs...)
			lcalls := flockCall.ReplaceAllString(wb.Calls(), "")

			wg := kitworld.New(t)
			gargs, genv := sc.setup(t, wg)
			port := goRun(wg, gargs, genv...)
			gcalls := gitDirFlag.ReplaceAllString(wg.Calls(), "git ")
			port.err = degradedLine.ReplaceAllString(port.err, "")

			if legacy.RC != sc.want || port.rc != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", legacy.RC, port.rc, sc.want, legacy.Out, legacy.Err, port.out, port.err)
			}
			for _, d := range [][3]string{
				{"stdout", wb.Norm(legacy.Out), wg.Norm(port.out)},
				{"stderr", wb.Norm(legacy.Err), wg.Norm(port.err)},
				{"calls", wb.Norm(lcalls), wg.Norm(gcalls)},
				{"state", snapshot(wb), snapshot(wg)},
			} {
				if d[1] != d[2] {
					t.Errorf("%s differ\n--- legacy\n%s\n--- go\n%s", d[0], d[1], d[2])
				}
			}
			if strings.TrimSpace(legacy.Out) == "" && sc.want != 0 {
				t.Errorf("the oracle printed nothing for a rc %d scenario: the comparison would prove nothing", sc.want)
			}
		})
	}
}
