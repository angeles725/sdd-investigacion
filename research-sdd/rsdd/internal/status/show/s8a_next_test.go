package show

import (
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// S8a: the --next cases of the bash suites that the case map marks UNMAPPED. Every scenario is in the S4 table (so
// the differential against the frozen script and the replay golden pin it); the legacy ASSERTIONS the bash cases
// made beyond the stdout verdict (stderr text, byte-identity with and without a file) are stated here and checked
// against the port by TestS8aNext. Case ids name the bash case: <suite> <line> <label>.

// s8aErr lists, per scenario, the stderr regexes the bash case asserted; s8aNoErr those it asserted absent.
var (
	s8aErr   = map[string][]string{}
	s8aNoErr = map[string][]string{}
)

// withErr registers the stderr assertions of a scenario and returns it.
func withErr(sc s4Scenario, has []string, not ...string) s4Scenario {
	s8aErr[sc.name], s8aNoErr[sc.name] = has, not
	return sc
}

const s8aDiscard = "| Priority | Gap | type | Status |\n|---|---|---|---|\n"

func s8aNextScenarios() []s4Scenario {
	qrows := []string{row("high", "G1 first gap", "pending"), row("medium", "G2 second gap", "pending"), row("low", "G3 third gap", "pending")}
	q := func(name, want, hdr string, extra string, errs ...string) s4Scenario {
		return withErr(n4(name, want, st4(hdr, "0", -1, extra, qrows...), nil, "--queue"), errs)
	}
	qr := func(name, want, hdr string, rows []string, errs ...string) s4Scenario {
		return withErr(n4(name, want, st4(hdr, "0", -1, "", rows...), nil, "--queue"), errs)
	}
	var scs []s4Scenario
	add := func(s ...s4Scenario) { scs = append(scs, s...) }

	// main suite 196-202: a gap text that mentions the stop-control phrase does not mask STOP.
	add(n4("s8a-L202-gap-text-mentioning-the-phrase-does-not-mask-stop", "STOP | read-only-investigable exhausted (0)",
		"# T\n\n"+fence("schema: research-state.v1", "covered_blocks: 0", "gaps_closed: 0", "known_gaps: 0", "investigable_open: 0", "requires_execution_open: 0", "blocked_open: 0")+
			"\n## Gap-backlog (prioritized)\n\n"+s8aDiscard+"| high | audit the read-only investigable subsystems | web | covered |\n\n## Blocked gaps\n- none\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n", nil))

	// main suite 282 and 406: --next is byte-identical with and without a ledger / an iteration-history table.
	base := func(name string) s4Scenario {
		return n4(name, "NEXT | high | the gap", blk(st4("", "0", -1, blockHdr+"- gpu profiling — needs: hardware\n", row("high", "the gap", "pending"))), nil)
	}
	ledger := "# T — Contradictions ledger\n\n| id | claim A (block) | claim B (block) | status | note |\n|---|---|---|---|---|\n| C1 | A says X (B1) | B says Y (B2) | open | cannot adjudicate yet |\n| C2 | foo=1 (B3) | foo=2 (B4) | open | |\n| C3 | baz (B5) | qux (B6) | resolved | B5 won per §14 |\n"
	hist := "\n## Iteration history\n\n| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |\n|---|---|---|---|---|---|\n| 1 | 2026-01-01 | g | B1 | no · inline | 0 |\n| 2 | 2026-01-02 | g | B2 | no · inline | 0 |\n| 3 | 2026-01-03 | g | B3 | no · inline | 0 |\n"
	led := base("s8a-L282-next-with-a-ledger")
	led.files["corpus/CONTRADICTIONS.md"] = ledger
	it := n4("s8a-L406-next-with-an-iteration-history", "NEXT | high | the gap", blk(st4("", "0", -1, blockHdr+"- gpu profiling — needs: hardware\n"+hist, row("high", "the gap", "pending"))), nil)
	add(base("s8a-L282-next-without-a-ledger"), led, base("s8a-L406-next-without-an-iteration-history"), it)

	// the queue suite: 2v, 2w, 2x, 2s, 4b, 4d.
	oob := "\n## Notes\n\n| Severity | Gap | Type | Status |\n|---|---|---|---|\n| deferred | G11 not a backlog row | web | parked |\n"
	add(
		withErr(n4("s8a-queue-2v-deferred-row-outside-the-backlog-is-unknown", "NEXT | high | G1 first gap", st4("next_session_queue: G11", "0", -1, oob, row("high", "G1 first gap", "pending")), nil, "--queue"),
			[]string{`WARN: queue-unknown-gap.*G11`}),
		qr("s8a-queue-2w-closed-row-first-pending-second", "NEXT | medium | G4 reopened", "next_session_queue: G4",
			[]string{row("high", "G4 old attempt", "covered"), row("medium", "G4 reopened", "pending")}, `WARN: queue-ambiguous-id.*G4.*2 rows`),
		qr("s8a-queue-2w-pending-row-first-closed-second", "NEXT | high | G4 reopened", "next_session_queue: G4",
			[]string{row("high", "G4 reopened", "pending"), row("medium", "G4 old attempt", "covered")}, `WARN: queue-ambiguous-id.*G4.*2 rows`),
		withErr(n4("s8a-queue-2x-closed-g1-plus-pending-g1-b", "NEXT | high | G1-b follow-up of G1",
			st4("PAUSED (operator-directed). Resume G1 first.\nnext_session_queue: G1", "0", -1, "",
				row("high", "G1 canonical gap", "covered"), row("high", "G1-b follow-up of G1", "pending"), row("medium", "G2 sibling", "pending")), nil, "--queue"),
			[]string{`queue-exhausted.*1 done`}, `queue-ambiguous-id`),
		q("s8a-queue-2s-column-0-declaration-inside-a-multi-line-comment", "NEXT | high | G1 first gap", "<!-- note\nnext_session_queue: G3\n-->", "", `queue-(absent|prose-only)`),
	)
	two := func(name, want, rootQ, actQ string, errs []string, flags ...string) s4Scenario {
		return withErr(m4(name, want, files{"corpus/RESEARCH-STATE.md": st4(rootQ, "0", -1, "", qrows...), "corpus/RESEARCH-STATE-act.md": st4(actQ, "0", -1, "", qrows...)}, flags...), errs)
	}
	add(
		two("s8a-queue-4b-root-reads-the-root-queue", "NEXT | low | G3 third gap", "next_session_queue: G3", "next_session_queue: G2", nil, "--queue", "--root"),
		two("s8a-queue-4d-sibling-queue-does-not-steer-the-root", "NEXT | high | G1 first gap", "", "next_session_queue: G3", []string{`queue-absent`}, "--queue", "--root"),
	)

	// root-pick 7 and 7b: a split layout (equal rank in different directories) resolves --focus to its own file.
	mk := func(gap, prio string) string { return st4("", "", 1, "", row(prio, gap, "pending")) }
	split := files{"corpus/a/RESEARCH-STATE-x.md": mk("split-a gap", "high"), "corpus/b/RESEARCH-STATE-y.md": mk("split-b gap", "medium")}
	add(
		m4("s8a-rootpick-7-split-layout-focus-x", "NEXT | high | split-a gap", split, "--focus", "x"),
		m4("s8a-rootpick-7b-split-layout-focus-y", "NEXT | medium | split-b gap", split, "--focus", "y"),
	)

	// main suite 1859: STALE beats RETRO-DUE (an inconsistent envelope with blocks_since_retro 11).
	add(n4("s8a-L1859-stale-beats-retro-due", "STALE | ",
		"# T-627d stale+bsr state\n\n"+fence("schema: research-state.v1", "covered_blocks: 0", "gaps_closed: 0", "known_gaps: 1", "investigable_open: 5", "requires_execution_open: 0", "blocked_open: 0", "undocumented_findings: 0", "blocks_since_retro: 11")+
			"\n## Gap-backlog\n\n"+s8aDiscard+"| high | stale-gap | web | pending |\n\n## Blocked gaps\n- none\n\n## Stop control\n- **Open gaps — read-only investigable**: 1\n", nil))
	return scs
}

// quietVerify is a verify-state that finds nothing wrong: the state files of S8a are valid, so the walk is reached.
var quietVerify = s4Env{env: func(string) string { return "" }, verify: func([]string, cli.Stdio) int { return 0 }}

func runQuietS4(t *testing.T, sc s4Scenario) (outcome, string) {
	t.Helper()
	root := sc.build(t)
	return runGoS4(t, sc, root, quietVerify)[0], root
}

// TestS8aNext checks the legacy assertions of the --next cases: the verdict, the stderr text the case named and
// the stderr text it asserted absent. (T-627d needs the real verify-state and is pinned by the S4 replay.)
func TestS8aNext(t *testing.T) {
	for _, sc := range s8aNextScenarios() {
		if strings.Contains(sc.name, "L1859") {
			continue
		}
		t.Run(sc.name, func(t *testing.T) {
			o, root := runQuietS4(t, sc)
			if got := strings.ReplaceAll(o.out, root, "<ROOT>"); !strings.HasPrefix(got, sc.want) {
				t.Errorf("stdout %q does not start with the legacy verdict %q", got, sc.want)
			}
			for _, re := range s8aErr[sc.name] {
				if !regexp.MustCompile(re).MatchString(o.err) {
					t.Errorf("stderr lacks /%s/:\n%s", re, o.err)
				}
			}
			for _, re := range s8aNoErr[sc.name] {
				if regexp.MustCompile(re).MatchString(o.err) {
					t.Errorf("stderr must not match /%s/:\n%s", re, o.err)
				}
			}
		})
	}
}

// The byte-identity guards (bash 282 and 406): the --next machine contract does not change with a ledger or an
// iteration-history table beside it, and neither is mentioned.
func TestS8aNextIsUnchangedByReportOnlyInputs(t *testing.T) {
	byName := map[string]s4Scenario{}
	for _, sc := range s8aNextScenarios() {
		byName[sc.name] = sc
	}
	for _, c := range []struct{ without, with, word string }{
		{"s8a-L282-next-without-a-ledger", "s8a-L282-next-with-a-ledger", "contradic"},
		{"s8a-L406-next-without-an-iteration-history", "s8a-L406-next-with-an-iteration-history", "saturation"},
	} {
		a, ra := runQuietS4(t, byName[c.without])
		b, rb := runQuietS4(t, byName[c.with])
		ga, gb := strings.ReplaceAll(a.out, ra, "<ROOT>"), strings.ReplaceAll(b.out, rb, "<ROOT>")
		if ga != gb || a.rc != b.rc || strings.Contains(strings.ToLower(gb), c.word) {
			t.Errorf("%s: --next leaked: before[%s] after[%s]", c.with, ga, gb)
		}
	}
}

// followups 6a, a DOCUMENTED divergence (2) of tool-registry.d/research-sdd-status.md: with verify-state.sh missing
// from the toolbelt the script answered `STALE | ... [first failure: unavailable — verify-state printed no FAIL
// line (rc=127)]`; the port refuses (exit 1, no verdict on stdout, a typed degraded line on stderr).
func TestS8aVerifyStateMissingIsDivergence2(t *testing.T) {
	empty := t.TempDir()
	rc, out, errb, _ := degradedWorld(t, empty, files{"corpus/RESEARCH-STATE.md": st4("", "0", -1, "", row("high", "G1 live", "pending"))}, "--next")
	if rc != 1 || out != "" || errb != "research-sdd-status: degraded: verify-state unavailable ("+empty+"/verify-state.sh not found)\n" {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out, errb)
	}
	if strings.Contains(out, "STALE") || strings.Contains(out, "rc=127") {
		t.Errorf("the port must not print the script's STALE pointer: %q", out)
	}
}
