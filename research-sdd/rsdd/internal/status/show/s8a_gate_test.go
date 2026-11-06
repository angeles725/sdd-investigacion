package show

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// S8a: the RETRO-DUE coverage, issues gate and terminal clean-check cases of the main suite and the clean-warn /
// queue suites that the case map marks UNMAPPED. All are in the S5 table; the stdout verdict is the scenario's
// `want`, and stderr, children and tree are pinned by the differential and the replay golden.

func s8aGateScenarios() []s5Scenario {
	const pairKey = "r.a.md.c.out"
	var scs []s5Scenario
	add := func(s ...s5Scenario) { scs = append(scs, s...) }
	const rootGap = "NEXT | high | the root gap"
	due := func(bsr string) string { return one("root", "pending", 1, bsr) }
	ex := one("root", "covered", 0, "0")
	note30 := "RETRO-DUE | 30 blocks since last retro (§18 threshold: 10)"
	cv := func(name, want string, r files) s5Scenario {
		return n5(name, want, due("30"), merge(nblk("r-", 1, 20), r), nil)
	}
	a := retros("a.md", "# Retro A\n")
	on := map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "0"}

	// T-1640c2: a derived count exactly at the threshold (10, lower than the declared 11) is NEXT.
	add(n5("s8a-L1894-T1640c2-derived-at-the-threshold-is-next", rootGap, due("11"), merge(nblk("r-", 1, 20), retros("r1.md", ct(10))), nil))
	// T-1640h: the winning coverage is the FIRST, MIDDLE or LAST retro in sorted order.
	for pos, v := range map[string][3]int{"first": {19, 10, 5}, "middle": {10, 19, 5}, "last": {10, 5, 19}} {
		add(cv("s8a-L1929-T1640h-highest-coverage-"+pos, rootGap, retros("2026-01-a.md", ct(v[0]), "2026-02-b.md", ct(v[1]), "2026-03-c.md", ct(v[2]))))
	}
	// T-1640i2: an over-range value LAST must not shadow a valid one (and is named per retro on stderr).
	add(cv("s8a-L1947-T1640i2-over-range-last-does-not-shadow", rootGap, retros("2026-01-a.md", ct(15), "2026-02-b.md", ct(99))))
	// T-1640j: a quoted `> covers_through:` line is not coverage; nor are fenced and excluded lines.
	add(cv("s8a-L1964-T1640j-fenced-quoted-excluded-lines-are-not-coverage", note30,
		retros("r1.md", "# R\n\n```\ncovers_through: B15\n```\n\n> covers_through: B15\n", "r2.md", "<!-- kit-retro: exclude -->\ncovers_through: B15\n")))
	// T-1640m3: a retro scoping every focus with its own slug covers them all.
	add(m5("s8a-L2006-T1640m3-every-focus-scoped-is-covered", "NEXT | high |",
		merge(files{"corpus/RESEARCH-STATE-alpha.md": one("alpha", "pending", 1, "11"), "corpus/RESEARCH-STATE-beta.md": one("beta", "pending", 1, "11")},
			nblk("alpha-", 1, 20), nblk("beta-", 1, 20), retros("r.md", "covers_through: B20 focus=alpha\ncovers_through: B20 focus=beta\n")), nil))
	// T-IDG-D: an active gap is NEXT; the issues gate is never reached although a retro is untracked.
	add(n5("s8a-L2102-IDG-D-active-gap-preempts-the-gate", rootGap, due("0"), merge(a, spec(pairKey, untracked1, "r.a.md.out", untracked1)), nil))
	// T-IDG-ENUM-EMPTY: an incomplete listing with ZERO retros found is unverified, not a bare STOP.
	empty := n5("s8a-L2447-IDG-ENUM-EMPTY-incomplete-listing-no-retros", stopLine+unverified, ex, files{"corpus/locked/x.md": "x\n"}, nil)
	empty.unreadable, empty.needsUser = []string{"corpus/locked"}, true
	add(empty)
	// clean-warn 3, 12b, 12c.
	add(
		n5("s8a-cleanwarn-3-next-verdict-runs-no-clean-check", rootGap, due("0"), spec("cc.rc", "1", "cc.out", "GARBAGE untracked stray.json\n"), on),
		n5("s8a-cleanwarn-12b-findings-reach-stderr-from-the-unverified-stop", stopLine+unverified, ex, merge(a, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: x\n", "cc.rc", "1", "cc.out", "GARBAGE untracked stray.json\n")), on),
		n5("s8a-cleanwarn-12c-opt-out-at-the-unverified-stop", stopLine+unverified, ex, merge(a, spec("r.a.md.c.rc", "1", "r.a.md.c.err", "degraded: x\n", "cc.rc", "1", "cc.out", "GARBAGE untracked stray.json\n")), map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": "1"}),
	)
	// queue 3c: an exhausted queue falls through, and ISSUES-DUE still fires.
	add(n5("s8a-queue-3c-issues-due-fires-when-the-queue-is-exhausted", "ISSUES-DUE | 1 untracked delta(s) in",
		st4("next_session_queue: G1", "0", 0, "", row("high", "G1 first gap", "covered")), merge(a, spec(pairKey, untracked1, "r.a.md.out", untracked1)), nil, "--queue"))
	return scs
}

// cleanwarn 8a: stdout and the exit code of every verdict path are identical with the clean-check on and off.
func TestS8aCleanCheckIsAdditive(t *testing.T) {
	const pairKey = "r.a.md.c.out"
	type world struct {
		name  string
		state string
		files files
	}
	for _, w := range []world{
		{"stop", one("root", "covered", 0, "0"), nil},
		{"next", one("root", "pending", 1, "0"), nil},
		{"stale", one("root", "pending", 5, "0"), nil},
		{"bootstrap", "", files{"corpus/notes.md": "x\n"}},
		{"gate", one("root", "covered", 0, "0"), merge(retros("a.md", "# A\n"), spec(pairKey, untracked1, "r.a.md.out", untracked1))},
	} {
		t.Run(w.name, func(t *testing.T) {
			var res [2]outcome
			for i, sw := range []string{"0", "1"} {
				f := w.files
				if w.state != "" {
					f = merge(files{stateRel: w.state}, f)
				}
				sc := m5("s8a-cc8-"+w.name, "", merge(f, spec("cc.rc", "1", "cc.out", "GARBAGE untracked stray.json\n")), map[string]string{"RSDD_STATUS_NO_CLEAN_CHECK": sw})
				root := sc.build(t)
				tb := t.TempDir()
				must(t, os.WriteFile(filepath.Join(tb, "clean-check.sh"), []byte("#!/bin/sh\n"), 0o755))
				e := s5Env{environ: sc.environ(root, t.TempDir(), "/nonexistent-bin"), toolbelt: tb}
				calls := &s5Calls{}
				o := runGoS5(t, sc, root, e, s5Drive{replay: &s5Replay{root: root, calls: calls}})[0]
				o.out = strings.ReplaceAll(o.out, root, "<ROOT>")
				res[i] = outcome{o.rc, o.out, ""}
			}
			if res[0] != res[1] {
				t.Errorf("stdout/rc differ with the check on and off\non:  %+v\noff: %+v", res[0], res[1])
			}
		})
	}
}
