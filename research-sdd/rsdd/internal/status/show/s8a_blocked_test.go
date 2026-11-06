package show

import (
	"regexp"
	"strings"
	"testing"
)

// S8a: blocked-rows.test.sh section 3d (kit #2024), the cases the case map marks UNMAPPED. The bash suite sabotaged
// the awk of ONE state file; here the is_blocked read of that file is made to fail (blockedHook, delegating to the
// real read for every other file). The legacy expectations are asserted as the bash suite stated them.

const (
	nbClosed  = "# T — Research State\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 1\nknown_gaps: 1\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n\n## Coverage\n- **Coverage metric**: 1 / 1 closed\n\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| high | done-gap | read | closed |\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"
	nbBlocked = "# T — Research State\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 1\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 1\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n\n## Coverage\n- **Coverage metric**: 0 / 1 closed\n\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| high | alpha-gap | read | pending |\n\n## Blocked gaps\n\n- alpha-gap — needs: hardware access\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"
)

var (
	nbMulti  = files{"corpus/RESEARCH-STATE-a.md": nbClosed, "corpus/RESEARCH-STATE-b.md": nbBlocked}
	nbPaused = merge(nbMulti, files{"corpus/FOCUSES.md": "# Focus Registry\n\n| Focus | Status | State file | Block prefix |\n|---|---|---|---|\n| a | active | RESEARCH-STATE-a.md | a- |\n| b | paused (1 open gap) | RESEARCH-STATE-b.md | b- |\n"})
	nbSplit  = files{"corpus/x/RESEARCH-STATE.md": nbClosed, "corpus/y/RESEARCH-STATE.md": nbBlocked}
)

// nbRun runs the real --next (or the default report when next is false) with the blocked read of every state file
// whose path contains failing replaced by rc 2.
func nbRun(t *testing.T, f files, failing string, next bool, flags ...string) outcome {
	t.Helper()
	verifyWith(t, 0, "")
	sc := m4("nb", "", f, flags...)
	root := sc.build(t)
	s, out, errb := stdio(root)
	s.Cwd = root
	args := sc.argv(0, root)
	if !next {
		args = append([]string{args[0]}, args[2:]...)
	}
	rc := run(args, s, func(cx *ctx) int {
		cx.blockedHook = func(g string) int {
			if failing != "" && strings.Contains(cx.state, failing) {
				return 2
			}
			return cx.isBlocked(g)
		}
		if next {
			return nextOr(liveSeams, s4Tail)(cx)
		}
		return cx.report()
	})
	return outcome{rc, strings.ReplaceAll(out.String(), root, "<ROOT>"), errb.String()}
}

func TestS8aNextDegradedNonHeadAndScoped(t *testing.T) {
	deg := func(o outcome) bool {
		return o.rc == 3 && strings.HasPrefix(o.out, "DEGRADED | ") && !strings.Contains(o.out, "NEXT | ")
	}
	t.Run("186-focus-b-degraded", func(t *testing.T) {
		if o := nbRun(t, nbMulti, "-b.md", true, "--focus", "b"); !deg(o) {
			t.Errorf("want DEGRADED, exit 3, no NEXT: %+v", o)
		}
	})
	t.Run("188-focus-a-scopes-the-refusal", func(t *testing.T) {
		if o := nbRun(t, nbMulti, "-b.md", true, "--focus", "a"); o.rc != 0 || strings.Contains(o.out, "DEGRADED") {
			t.Errorf("a healthy picked focus must answer: %+v", o)
		}
	})
	t.Run("192-paused-healthy-twin", func(t *testing.T) {
		if o := nbRun(t, nbPaused, "", true); o.rc != 0 || !strings.HasPrefix(o.out, "STOP | read-only-investigable exhausted (0)") {
			t.Errorf("want exit 0 and the exhausted STOP: %+v", o)
		}
	})
	// DOCUMENTED (12): the script's per-file probe said `unreadable for y/RESEARCH-STATE.md `; the port has no probe
	// (blocked_open_count rc 3 has no counterpart) and names the relative path in the resolving message instead.
	t.Run("227-split-layout-names-the-file-by-relative-path", func(t *testing.T) {
		o := nbRun(t, nbSplit, "/y/", true)
		if o.rc != 3 || !strings.Contains(o.out, "while resolving alpha-gap in y/RESEARCH-STATE.md ") || strings.Contains(o.out, "x/RESEARCH-STATE") {
			t.Errorf("want exit 3 naming y/RESEARCH-STATE.md only: %+v", o)
		}
	})
}

var nextStepRE = regexp.MustCompile(`(?m)^.*next step.*$`)

func TestS8aDisplayDegradedNonHead(t *testing.T) {
	for _, c := range []struct {
		name, id string
		f        files
	}{
		{"196-non-head-focus-degraded", "196", nbMulti},
		{"199-paused-focus-degraded", "199", nbPaused},
	} {
		t.Run(c.name, func(t *testing.T) {
			o := nbRun(t, c.f, "-b.md", false)
			ns := strings.Join(nextStepRE.FindAllString(o.out, -1), "\n")
			if !regexp.MustCompile(`next step .*: DEGRADED`).MatchString(ns) || regexp.MustCompile(`next step .*(NEXT|STOP) \|`).MatchString(ns) {
				t.Errorf("next step must be DEGRADED with no NEXT/STOP verdict, got %q", ns)
			}
		})
	}
	// DOCUMENTED (12): the script's per-file probe named the non-head file (`DEGRADED (blocked-rows derivation
	// unreadable for RESEARCH-STATE-b.md ...)`) and set the reason-codes footer; the port probes only the head state,
	// so a non-head failure surfaces from the walk as `DEGRADED | blocked-rows read failed while resolving ...` and
	// sets no footer.
	t.Run("203-non-head-next-step-text", func(t *testing.T) {
		o := nbRun(t, nbMulti, "-b.md", false)
		if !strings.Contains(o.out, "next step       : DEGRADED | blocked-rows read failed while resolving alpha-gap in RESEARCH-STATE-b.md") {
			t.Errorf("next step: %q", nextStepRE.FindString(o.out))
		}
	})
	t.Run("222-non-head-sets-no-reason-codes-footer", func(t *testing.T) {
		o := nbRun(t, nbMulti, "-b.md", false)
		if n := strings.Count(o.out, "\n  reason codes    : "); n != 0 {
			t.Errorf("reason-codes footer printed %d times, the port prints none for a non-head failure", n)
		}
	})
	t.Run("202-display-healthy-twin-carries-the-stop-verdict", func(t *testing.T) {
		if o := nbRun(t, nbPaused, "", false); !strings.Contains(o.out, "next step       : STOP | ") {
			t.Errorf("healthy twin lacks the STOP verdict: %q", nextStepRE.FindString(o.out))
		}
	})
}
