//go:build !nodiff

package waitmerge

import (
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// The differential test: every scenario runs against the frozen legacy kit-wait-merge.sh (testdata/legacy) and
// against run, each in a fresh identical world, and the two must agree on exit code, stdout, stderr and the ordered
// call log. Declared divergences (each pinned by its own Go test): the `DEGRADED: ...` stderr line of an exit 3, the
// default merge gate (the bash ran a sibling merge-gate.sh, Go runs `rsdd gate merge`) so KIT_MERGE_GATE is always set
// here, and a relative worktree (the bash passed the relative path on to the merge gate).
type scenario struct {
	name  string
	setup func(w *kitworld.World)
	args  []string // @WT@ and @W@ stand for the worktree and the case directory
	env   []string
	want  int
}

func scenarios() []scenario {
	wt := func(a ...string) []string { return append(a, "@WT@", "7") }
	pend := func(w *kitworld.World) { w.Rule("gh", "pr checks*", 8, "pr-checks-pending.txt", 2, "") }
	mgOpen := func(rc int, fx string, times int) func(w *kitworld.World) {
		return func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", rc, fx, times, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", times, "")
		}
	}
	return []scenario{
		{"happy", func(w *kitworld.World) {}, wt(), nil, 0},
		{"base-ref", func(w *kitworld.World) {}, wt("--base-ref", "up/dev"), nil, 0},
		{"dashdash", func(w *kitworld.World) {}, wt("--"), nil, 0},
		{"pending-then-pass", pend, wt(), nil, 0},
		{"blip-on-view", func(w *kitworld.World) { w.Rule("gh", "pr view*", 1, "", 1, "") }, wt(), nil, 0},
		{"view-always-fails", func(w *kitworld.World) { w.Rule("gh", "pr view*", 1, "", 0, "") }, wt(), nil, 19},
		{"cifail", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 1, "pr-checks-fail.txt", 0, "") }, wt(), nil, 17},
		{"checks-never-green", func(w *kitworld.World) { w.Rule("gh", "pr checks*", 8, "pr-checks-pending.txt", 0, "") }, wt(), []string{"KIT_POLL_MAX=2"}, 0},
		{"poll-max-zero", func(w *kitworld.World) {}, wt(), []string{"KIT_POLL_MAX=0"}, 0},
		{"poll-max-bad", func(w *kitworld.World) {}, wt(), []string{"KIT_POLL_MAX=x"}, 0},
		{"degraded-then-ok", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 3, "merge-gate-degraded.txt", 1, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 1, "")
		}, wt(), nil, 0},
		{"degraded-forever", mgOpen(3, "merge-gate-degraded.txt", 0), wt(), nil, 18},
		{"review-due", mgOpen(1, "merge-gate-review-due.txt", 0), wt(), nil, 19},
		{"ci-pending-forever", func(w *kitworld.World) {
			w.Rule("merge-gate.sh", "*", 1, "merge-gate-ci-pending.txt", 0, "")
			w.Rule("gh", "pr view*", 0, "pr-state-open.txt", 0, "")
		}, wt(), nil, 19},
		{"allow-but-open", mgOpen(0, "merge-gate-merged.txt", 0), wt(), nil, 19},
		{"tries-one", mgOpen(3, "merge-gate-degraded.txt", 0), wt(), []string{"KIT_MERGE_TRIES=1"}, 18},
		{"tries-zero", mgOpen(3, "merge-gate-degraded.txt", 0), wt(), []string{"KIT_MERGE_TRIES=0"}, 19},
		{"tries-bad", mgOpen(3, "merge-gate-degraded.txt", 0), wt(), []string{"KIT_MERGE_TRIES=x"}, 1},
		{"expect-match", func(w *kitworld.World) { w.Rule("gh", "pr view 7 --json headRefOid*", 0, "pr-info-match.txt", 0, "") }, wt("--expect-head", "abc1234"), nil, 0},
		{"expect-nomc", func(w *kitworld.World) { w.Rule("gh", "pr view 7 --json headRefOid*", 0, "pr-info-nomc.txt", 0, "") }, wt("--expect-head", "abc1234"), nil, 0},
		{"expect-oob", func(w *kitworld.World) { w.Rule("gh", "pr view 7 --json headRefOid*", 0, "pr-info-oob.txt", 0, "") }, wt("--expect-head", "abc1234"), nil, 33},
		{"expect-unreadable", func(w *kitworld.World) { w.Rule("gh", "pr view 7 --json headRefOid*", 0, "empty.txt", 0, "") }, wt("--expect-head", "abc1234"), nil, 18},
		{"expect-failing", func(w *kitworld.World) { w.Rule("gh", "pr view 7 --json headRefOid*", 1, "", 0, "") }, wt("--expect-head", "abc1234"), nil, 18},
		{"noargs", func(w *kitworld.World) {}, nil, nil, 2},
		{"onearg", func(w *kitworld.World) {}, []string{"@WT@"}, nil, 2},
		{"threeargs", func(w *kitworld.World) {}, []string{"@WT@", "7", "8"}, nil, 2},
		{"unknown", func(w *kitworld.World) {}, wt("--bogus"), nil, 2},
		{"unknown-after-flag", func(w *kitworld.World) {}, wt("--base-ref", "b", "-x"), nil, 2},
		{"basenovalue", func(w *kitworld.World) {}, []string{"--base-ref"}, nil, 2},
		{"expectnovalue", func(w *kitworld.World) {}, []string{"--expect-head"}, nil, 2},
		{"prletters", func(w *kitworld.World) {}, []string{"@WT@", "7a"}, nil, 2},
		{"prempty", func(w *kitworld.World) {}, []string{"@WT@", ""}, nil, 2},
		{"prnegative", func(w *kitworld.World) {}, []string{"@WT@", "-7"}, nil, 2},
		{"nowt", func(w *kitworld.World) {}, []string{"@W@/nope", "7"}, nil, 2},
		{"nogh", func(w *kitworld.World) { w.Drop("gh") }, wt(), nil, 3},
		{"nomergegate", func(w *kitworld.World) {}, wt(), []string{"KIT_MERGE_GATE=@W@/absent.sh"}, 3},
		{"mergegatedir", func(w *kitworld.World) {}, wt(), []string{"KIT_MERGE_GATE=@W@"}, 3},
		{"help", func(w *kitworld.World) {}, []string{"--help"}, nil, 0},
		{"helpafterflag", func(w *kitworld.World) {}, []string{"--base-ref", "b", "-h", "--bogus"}, nil, 0},
		{"helpafterbad", func(w *kitworld.World) {}, []string{"--bogus", "-h"}, nil, 2},
	}
}

// divergent are the scenarios whose Go answer is declared different (tool-registry.d/kit-wait-merge.md): the legacy
// side is still asserted (scenario.want), the Go side must answer rc and stdout exactly.
var divergent = map[string]struct {
	rc  int
	out string
}{
	"poll-max-bad": {2, "kit-wait-merge: usage: KIT_POLL_MAX must be a whole number: x\n"},
	"tries-bad":    {2, "kit-wait-merge: usage: KIT_MERGE_TRIES must be a whole number: x\n"},
}

func expand(w *kitworld.World, in []string) []string {
	out := make([]string, len(in))
	for i, x := range in {
		out[i] = strings.ReplaceAll(strings.ReplaceAll(x, "@WT@", w.Wt), "@W@", w.Dir)
	}
	return out
}

// build makes a world for sc: the case's own rules first, then the happy defaults.
func build(t *testing.T, sc scenario) (*kitworld.World, []string, []string) {
	w := kitworld.New(t)
	sc.setup(w)
	happy(w)
	env := append([]string{mergeGateEnv(t, w)}, expand(w, sc.env)...)
	return w, expand(w, sc.args), env
}

func TestWaitMergeDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "kit-wait-merge.sh", "kit-maint-common.sh")
	for _, sc := range scenarios() {
		t.Run(sc.name, func(t *testing.T) {
			wb, bargs, benv := build(t, sc)
			legacy := kitworld.RunBash(t, wb.Wt, wb.Env(benv...), stage+"/kit-wait-merge.sh", bargs...)

			wg, gargs, genv := build(t, sc)
			s, o, e := wg.Stdio(wg.Wt, genv...)
			rc := run(gargs, s, deps{sleep: func(time.Duration) {}})
			port := result{o.String(), e.String(), rc}
			port.err = degradedLine.ReplaceAllString(port.err, "")

			if d, ok := divergent[sc.name]; ok {
				if legacy.RC != sc.want || port.rc != d.rc || port.out != d.out || port.err != "" {
					t.Errorf("declared divergence: legacy rc %d (want %d); go rc %d out=%q err=%q (want rc %d out=%q)", legacy.RC, sc.want, port.rc, port.out, port.err, d.rc, d.out)
				}
				return
			}
			if legacy.RC != sc.want || port.rc != sc.want {
				t.Fatalf("exit codes: legacy %d, go %d, scenario wants %d\nlegacy out=%q err=%q\ngo out=%q err=%q", legacy.RC, port.rc, sc.want, legacy.Out, legacy.Err, port.out, port.err)
			}
			for _, d := range [][3]string{
				{"stdout", wb.Norm(legacy.Out), wg.Norm(port.out)},
				{"stderr", wb.Norm(legacy.Err), wg.Norm(port.err)},
				{"calls", wb.Norm(wb.Calls()), wg.Norm(wg.Calls())},
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
