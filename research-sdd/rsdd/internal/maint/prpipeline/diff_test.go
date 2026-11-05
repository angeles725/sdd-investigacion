//go:build !nodiff

package prpipeline

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// The differential test: every scenario runs against the frozen legacy pipeline (testdata/legacy: kit-pr-pipeline.sh
// with the kit-gate.sh and kit-wait-merge.sh it calls, and stub kit-rdd-*.sh) and against run (with fake review
// steps), each in a fresh identical world; exit code, stdout, stderr, the ordered call log and the state directory must
// agree. Declared divergences (each pinned by its own Go test): the `DEGRADED: ...` stderr line of an exit 3, the
// dropped `flock -w N 9` call (the lock is taken in process), the `-C <worktree>` of git, and the scenarios in
// `divergent` below.
type scenario struct {
	name  string
	setup func(w *kitworld.World)
	args  []string // @WT@ and @W@ stand for the worktree and the case directory
	env   []string
	want  int
}

var base = []string{"--state-dir", "@W@/st"}

func a(extra ...string) []string {
	return append(append(append([]string(nil), base...), extra...), "@WT@", "7", "feat/x")
}

func nop(*kitworld.World) {}

func scenarios() []scenario {
	drive := func(w *kitworld.World, text string) {
		_ = os.WriteFile(w.Dir+"/drive.txt", []byte(text), 0o644)
	}
	gatecmd := []string{"--gate-cmd", `echo GATE-RAN >> "$SHIM_STATE/calls.log"`}
	return []scenario{
		{"happy", nop, a(), nil, 0},
		{"dry", nop, a("--dry-run"), nil, 0},
		{"dry-all", nop, a("--dry-run", "--consent", "granted", "--serial", "--size-check", "true", "--base-ref", "up/dev", "--remote", "fork"), nil, 0},
		{"dry-nogate", nop, a("--dry-run", "--no-gate"), nil, 0},
		{"dry-gatecmd", nop, a(append([]string{"--dry-run"}, gatecmd...)...), nil, 0},
		{"help", nop, []string{"--help"}, nil, 0},
		{"nogate", nop, a("--no-gate"), nil, 0},
		{"gatecmd", nop, a(gatecmd...), nil, 0},
		{"serial", nop, a("--serial"), nil, 0},
		{"remote-base", nop, a("--remote", "fork", "--base-ref", "up/dev"), nil, 0},
		{"sizecheck-ok", nop, a("--size-check", `echo "SIZE $KIT_PR $KIT_WORKTREE" >> "$SHIM_STATE/calls.log"`), nil, 0},
		{"sizecheck-fail", nop, a("--size-check", "exit 9"), nil, 20},
		{"dirty", func(w *kitworld.World) { w.Rule("git", "*status --porcelain*", 0, "dirty.txt", 0, "") }, a(), nil, 24},
		{"fetch-blip", func(w *kitworld.World) { w.Rule("git", "*fetch*", 1, "", 1, "") }, a(), nil, 0},
		{"fetch-fails", func(w *kitworld.World) { w.Rule("git", "*fetch*", 1, "", 0, "") }, a(), nil, 21},
		{"bad-base", func(w *kitworld.World) { w.Rule("git", "*merge-base --is-ancestor*", 128, "", 0, "") }, a(), nil, 23},
		{"behind-merges", func(w *kitworld.World) { w.Rule("git", "*merge-base --is-ancestor*", 1, "", 0, "") }, a(), nil, 0},
		{"conflict", func(w *kitworld.World) {
			w.Rule("git", "*merge-base --is-ancestor*", 1, "", 0, "")
			w.Rule("git", "*merge -q --no-edit*", 1, "", 0, "")
			w.Rule("git", "*ls-files -u*", 0, "unmerged.txt", 0, "")
		}, a(), nil, 11},
		{"merge-error", func(w *kitworld.World) {
			w.Rule("git", "*merge-base --is-ancestor*", 1, "", 0, "")
			w.Rule("git", "*merge -q --no-edit*", 1, "", 0, "")
		}, a(), nil, 25},
		{"push-fails", func(w *kitworld.World) { w.Rule("git", "*push*", 1, "", 0, "") }, a(), nil, 12},
		{"rdd-not-due", nop, a(), []string{"STUB_START_RC=10"}, 0},
		{"rdd-consent", nop, a(), []string{"STUB_START_RC=15"}, 15},
		{"rdd-granted-flag", nop, a("--consent", "granted"), nil, 0},
		{"rdd-start-degraded", nop, a(), []string{"STUB_START_RC=3"}, 3},
		{"rdd-start-error", nop, a(), []string{"STUB_START_RC=7"}, 14},
		{"rdd-drive-output", func(w *kitworld.World) {
			drive(w, "RUN a\nLAUNCH b\nl1\nl2\nl3\nl4\nl5\nl6\nl7\n"+strings.Repeat("x", 305)+"\n")
		}, a(), []string{"STUB_DRIVE_OUT=@W@/drive.txt"}, 0},
		{"rdd-drive-consent", func(w *kitworld.World) { drive(w, "RUN a\nenvelope\n") }, a(), []string{"STUB_DRIVE_RC=15", "STUB_DRIVE_OUT=@W@/drive.txt"}, 15},
		{"rdd-drive-degraded", nop, a(), []string{"STUB_DRIVE_RC=3"}, 3},
		{"rdd-drive-fail", func(w *kitworld.World) { drive(w, "bad\n") }, a(), []string{"STUB_DRIVE_RC=9", "STUB_DRIVE_OUT=@W@/drive.txt"}, 13},
		{"gate-fails", nop, a("--gate-cmd", "exit 7"), nil, 16},
		{"gate-usage", nop, a("--serial", "--gate-cmd", "true"), nil, 2},
		{"cifail", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 1, "pr-checks-fail.txt", 0, "") }, a(), nil, 17},
		{"merge-degraded", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 3, "merge-gate-degraded.txt", 0, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 0, "")
		}, a(), nil, 18},
		{"state-blip", func(w *kitworld.World) { w.Rule("gh", "pr view*", 1, "", 1, "") }, a(), nil, 0},
		{"state-blip-forever", func(w *kitworld.World) {
			w.Rule("gh", "pr view*", 1, "", 0, "")
			w.Rule("merge-gate.sh", "*", 1, "merge-gate-review-due.txt", 0, "")
		}, a(), nil, 19},
		{"checks-blip", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 1, "", 2, "") }, a(), nil, 0},
		{"merge-output-tail", func(w *kitworld.World) { w.Rule("merge-gate.sh", "*", 0, "merge-gate-merged-long.txt", 0, "") }, a(), nil, 0},
		{"gate-summary-tail", nop, a("--gate-cmd", `i=0; while [ $i -lt 20 ]; do i=$((i+1)); echo "n$i passed"; done`), nil, 0},
		{"gate-summary-fail", nop, a("--gate-cmd", `echo "1 passed"; echo "FAIL  x"; exit 3`), nil, 16},
		{"not-merged", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 1, "merge-gate-review-due.txt", 0, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 0, "")
		}, a(), nil, 19},
		{"noargs", nop, nil, nil, 2},
		{"twoargs", nop, []string{"@WT@", "7"}, nil, 2},
		{"unknown", nop, a("--bogus"), nil, 2},
		{"consent-bad", nop, a("--consent", "yes"), nil, 2},
		{"consent-last", nop, []string{"--consent"}, nil, 2},
		{"gatecmd-last", nop, []string{"--gate-cmd"}, nil, 2},
		{"prletters", nop, []string{"@WT@", "7a", "b"}, nil, 2},
		{"nowt", nop, []string{"@W@/nope", "7", "b"}, nil, 2},
		{"state-in-repo", nop, []string{"--state-dir", "@WT@/state", "@WT@", "7", "b"}, nil, 2},
		{"no-gentle-ai", func(w *kitworld.World) { w.Drop("gentle-ai") }, a(), nil, 3},
		{"no-gh", func(w *kitworld.World) { w.Drop("gh") }, a(), nil, 3},
		{"no-flock", func(w *kitworld.World) { w.Drop("flock") }, a(), nil, 3},
		{"no-flock-nogate", func(w *kitworld.World) { w.Drop("flock") }, a("--no-gate"), nil, 0},
		{"merge-gate-missing", nop, a(), []string{"KIT_MERGE_GATE=@W@/nope"}, 3},
		{"knob-poll-max-bad", nop, a(), []string{"KIT_POLL_MAX=abc"}, 2},
		{"knob-tries-bad", nop, a(), []string{"KIT_MERGE_TRIES=x"}, 2},
	}
}

// divergent are the scenarios whose Go answer is declared different (tool-registry.d/kit-pr-pipeline.md).
var divergent = map[string]struct {
	legacyRC, goRC int
}{
	"no-python3":        {3, 0}, // python3 is no longer a dependency
	"knob-poll-max-bad": {0, 2}, // a non-numeric knob is a usage error (the bash read it as 0)
	"knob-tries-bad":    {19, 2},
}

func expand(w *kitworld.World, in []string) []string {
	out := make([]string, len(in))
	for i, x := range in {
		out[i] = strings.ReplaceAll(strings.ReplaceAll(x, "@WT@", w.Wt), "@W@", w.Dir)
	}
	return out
}

func build(t *testing.T, sc scenario) (*kitworld.World, []string, []string) {
	w := kitworld.New(t)
	sc.setup(w)
	happy(w)
	env := append([]string{prepare(t, w)}, expand(w, sc.env)...)
	return w, expand(w, sc.args), env
}

func snapshot(w *kitworld.World) string {
	var lines []string
	_ = filepath.Walk(w.Dir+"/st", func(p string, fi os.FileInfo, err error) error {
		if err != nil || fi.IsDir() {
			return nil
		}
		b, _ := os.ReadFile(p)
		lines = append(lines, "file "+strings.TrimPrefix(p, w.Dir)+" ["+w.Norm(string(b))+"]")
		return nil
	})
	sort.Strings(lines)
	return strings.Join(lines, "\n")
}

func TestPipelineDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "kit-pr-pipeline.sh", "kit-gate.sh", "kit-wait-merge.sh", "kit-maint-common.sh")
	writeStubs(t, stage)
	scs := scenarios()
	scs = append(scs, scenario{"no-python3", func(w *kitworld.World) { w.Drop("python3") }, a(), nil, 3})
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			wb, bargs, benv := build(t, sc)
			legacy := kitworld.RunBash(t, wb.Wt, wb.Env(benv...), stage+"/kit-pr-pipeline.sh", bargs...)
			lcalls := flockCall.ReplaceAllString(wb.Calls(), "")

			wg, gargs, genv := build(t, sc)
			start, drive := fakes()
			s, o, e := wg.Stdio(wg.Wt, genv...)
			rc := run(gargs, s, deps{start: start, drive: drive, sleep: func(time.Duration) {}})
			port := result{o.String(), e.String(), rc}
			gcalls := gitDirFlag.ReplaceAllString(wg.Calls(), "git ")
			port.err = degradedLine.ReplaceAllString(port.err, "")

			if d, ok := divergent[sc.name]; ok {
				if legacy.RC != d.legacyRC || port.rc != d.goRC {
					t.Errorf("declared divergence: legacy rc %d (want %d), go rc %d (want %d)\n%q", legacy.RC, d.legacyRC, port.rc, d.goRC, port.out)
				}
				return
			}
			if legacy.RC != sc.want || port.rc != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", legacy.RC, port.rc, sc.want, legacy.Out, legacy.Err, port.out, port.err)
			}
			for _, d := range [][3]string{
				{"stdout", wb.Norm(strings.Replace(legacy.Out, "gentle-ai python3, flock", "gentle-ai, flock", 1)), wg.Norm(helpLegacy(port.out))}, // help: python3 is no longer a dependency, and `interrupted` is new
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

// helpLegacy drops the one help line the legacy script cannot have: the `interrupted` state is new in the port.
func helpLegacy(out string) string {
	var keep []string
	for _, l := range strings.Split(out, "\n") {
		if !strings.HasPrefix(l, "#   interrupted ") {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}
