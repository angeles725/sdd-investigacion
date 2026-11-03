//go:build unix && !nodiff

package verify

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// A seeded generator of RESEARCH-STATE corpora, compared against the frozen legacy script. It reaches the
// combinations the curated cases do not: random mixes of envelope values, backlog rows, blocked sections,
// prose checks, block files, FOCUSES.md cells, INDEX.md and hook files. RSDD_STATE_FUZZ_N raises the count.

func pick(r *rand.Rand, xs ...string) string { return xs[r.Intn(len(xs))] }

func genEnvelope(r *rand.Rand) string {
	var b strings.Builder
	b.WriteString("<!-- research-state.v1 -->\nschema: research-state.v1\n")
	vals := []string{"0", "0", "1", "1", "2", "3", "4", "5", "7", "11", "010", "abc", "", "-1"}
	for _, k := range []string{"covered_blocks", "gaps_closed", "known_gaps", "investigable_open", "requires_execution_open", "blocked_open", "deferred_open", "undocumented_findings", "blocks_since_retro"} {
		switch n := r.Intn(10); {
		case n < 7:
			fmt.Fprintf(&b, "%s: %s\n", k, pick(r, vals...))
		case n == 7:
			fmt.Fprintf(&b, "%s:%s\n", k, pick(r, "0", "3"))
		}
	}
	switch r.Intn(8) {
	case 0:
		b.WriteString("block_scope: per-focus\n")
	case 1:
		b.WriteString("block_scope: shared-global\n")
	case 2:
		b.WriteString("block_scope: weird\n")
	}
	if r.Intn(6) == 0 {
		b.WriteString("known_stale_warns: " + pick(r, "p7-index-placeholder", "check-2-covered-blocks, p7-index-placeholder", "other") + "\n")
	}
	b.WriteString("<!-- /research-state.v1 -->\n")
	return b.String()
}

func genBacklog(r *rand.Rand) string {
	var b strings.Builder
	b.WriteString(pick(r, "## Gap-backlog", "## Gap-backlog", "## Gap-backlog (prioritized)", "## Gap backlog", "## Backlog", "## Gap-backlog (x") + "\n\n")
	cols := pick(r, "4", "4", "4", "5", "6")
	switch cols {
	case "4":
		b.WriteString("| Priority | Gap | Type | Status |\n|---|---|---|---|\n")
	case "5":
		b.WriteString("| Priority | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n")
	default:
		b.WriteString("| P | a | b | c | d | e |\n|---|---|---|---|---|---|\n")
	}
	prios := []string{"high", "high", "medium", "low", "low", "deferred", "~~high~~", "—", "High", "high (ctx)"}
	if r.Intn(25) == 0 {
		prios = append(prios, "med", "urgent")
	}
	stats := []string{"pending", "pending", "pending (x)", "✅ closed", "blocked (needs key)", "requires-execution", "**requires-execution** (x)", "re-typed", "retyped", "blocked-on-hw", "unavailable", "**pending**", "~~pending~~", "parked", "blocked", "refused, x unblock: p", "covered"}
	gaps := []string{"G1 one", "B1-G2 two", "named", "~~struck~~", "G3: x", "Builders", "G7 first", "AB. text"}
	for i, n := 0, r.Intn(8); i < n; i++ {
		p, st, gap := pick(r, prios...), pick(r, stats...), pick(r, gaps...)
		switch cols {
		case "4":
			fmt.Fprintf(&b, "| %s | %s | w | %s |\n", p, gap, st)
		case "5":
			fmt.Fprintf(&b, "| %s | %s | %s | a | %s |\n", p, strings.SplitN(gap, " ", 2)[0], gap, st)
		default:
			fmt.Fprintf(&b, "| %s | %s | w | x | y | %s |\n", p, gap, st)
		}
		if r.Intn(12) == 0 {
			b.WriteString("| high | extra | cell | covered | x |\n")
		}
	}
	return b.String()
}

func genBlocked(r *rand.Rand) string {
	var b strings.Builder
	b.WriteString(pick(r, "## Blocked gaps", "## Blocked gaps", "## Non-investigable gaps", "## Blocked / requires-execution gaps", "## Child gaps surfaced at close") + "\n")
	lines := []string{"- named — needs: a key", "- G7 first - needs: x; tried: y; unblock: z", "- none", "- Builders needs: hw", "  - nested — needs: x", "- ~~G9~~ — needs: gone", "- done CLOSED — needs: x", "- NOT YET CLOSED — needs: x", "- G3 ✅ needs: y", "G54 — text **needs:** thing", "tried: stuff **tried:** y", "  `needs:` continuation", "", "- unblock: first — needs: later", "- AB. — needs: id", "- thing NO CLOSED needs: x"}
	for i, n := 0, r.Intn(7); i < n; i++ {
		b.WriteString(pick(r, lines...) + "\n")
	}
	return b.String()
}

func genProse(r *rand.Rand) string {
	var parts []string
	pool := []string{
		"coverage metric: 5 / 5 declared gaps closed", "**Coverage metric**: 3/4", "coverage metric: 16/16", "coverage (after B3): 22/16", "gaps closed: 1/9",
		"Covered blocks: 2 so far", "covered blocks: 9", "## Covered blocks\nB1, B2 and B2\n", "## Stretch goal\n- realistic: 4\n", "## Stretch goal\n- realistic: 4\nstretch: 9\n",
		"## Stop control\n- **Open gaps — read-only investigable**: 2\n", "## Stop control\nread-only investigable: **0**\n", "## Iteration history\n| # | Block | Gap |\n|---|---|---|\n| 1 | B3 | x |\n| 2 | B3, B4 | y |\ncoverage metric: 1/99\n",
		"## History\ncoverage metric: 2/77\n", "a line | with | pipes", "text with the word pending in prose", "| Gap closed | 4 / 5 |",
	}
	for i, n := 0, r.Intn(5); i < n; i++ {
		parts = append(parts, pick(r, pool...))
	}
	return strings.Join(parts, "\n") + "\n"
}

// genClean is a corpus whose envelope agrees with its files, so the generator also reaches the runs that exit 0
// and the checks that only fire on a consistent state.
func genClean(t *testing.T, r *rand.Rand, d string) []string {
	body := sdConsistent()
	if r.Intn(2) == 0 {
		body += pick(r, "coverage metric: 4 / 9 gaps closed\n", "Covered blocks: 0\n", "## Stretch goal\n- realistic: 1\nstretch: 2\n", "")
	}
	sdWrite(t, filepath.Join(d, "RESEARCH-STATE.md"), body)
	if r.Intn(3) == 0 {
		sdWrite(t, filepath.Join(d, ".claude", "hooks", "h.sh"), pick(r, "<KIT>\n", "echo ok\n"))
	}
	return []string{d}
}

func genCorpus(t *testing.T, r *rand.Rand, d string) []string {
	if r.Intn(4) == 0 {
		return genClean(t, r, d)
	}
	sections := []string{genProse(r)}
	if r.Intn(10) != 0 {
		sections = append(sections, genBacklog(r))
	}
	for i, n := 0, r.Intn(3); i < n; i++ {
		sections = append(sections, genBlocked(r))
	}
	r.Shuffle(len(sections), func(i, j int) { sections[i], sections[j] = sections[j], sections[i] })
	env := genEnvelope(r)
	body := strings.Join(sections, "\n")
	if r.Intn(12) == 0 {
		env = ""
	}
	state := "# Research State\n\n"
	if r.Intn(2) == 0 {
		state += env + "\n" + body
	} else {
		state += body + "\n" + env
	}
	if r.Intn(8) == 0 {
		state = strings.ReplaceAll(state, "\n", "\r\n")
	}
	name := pick(r, "RESEARCH-STATE.md", "RESEARCH-STATE.md", "RESEARCH-STATE-auth.md")
	sdWrite(t, filepath.Join(d, name), state)
	args := []string{d}
	if name != "RESEARCH-STATE.md" && r.Intn(2) == 0 {
		args = append(args, "--focus", "auth")
	}
	for _, f := range r.Perm(6)[:r.Intn(4)] {
		sdWrite(t, filepath.Join(d, []string{"auth-block1.md", "auth-block2-x.md", "db-block3.md", "x-bloque4.md", "blocked-notes.md", "y-block5.md"}[f]), "b\n")
	}
	switch r.Intn(6) {
	case 0:
		sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Blocks |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | "+pick(r, "B1–B3", "B1-B5", "B9–B2", "`cob-block<N>.md`", "n/a")+" |\n")
	case 1:
		sdWrite(t, filepath.Join(d, "FOCUSES.md"), "| Focus | Slug | x | State | Prefix |\n|---|---|---|---|---|\n| root | r | x | RESEARCH-STATE.md | `"+pick(r, "db-", "auth-", "x-")+"block<N>.md` |\n")
	}
	if r.Intn(4) == 0 {
		sdWrite(t, filepath.Join(d, "INDEX.md"), pick(r, "# <SUBJECT>\n", "# clean\n", "<KIT> <YYYY-MM-DD>\n"))
	}
	if r.Intn(5) == 0 {
		sdWrite(t, filepath.Join(d, ".claude", "hooks", "h.sh"), pick(r, "<KIT>\n", "#<KIT>\n", "echo ok\n", "a <TARGET> <prefix> <SUBJECT>\n"))
		if r.Intn(2) == 0 {
			sdWrite(t, filepath.Join(d, ".claude", "settings.json"), `{"hooks":{"a":{"command":"bash $CLAUDE_PROJECT_DIR/.claude/hooks/h.sh"},"b":{"command":"x.sh"}}}`)
		}
	}
	if r.Intn(8) == 0 {
		sdWrite(t, filepath.Join(d, "RESEARCH-STATE-db.md"), state)
	}
	return args
}

func TestDifferentialStateRandom(t *testing.T) {
	n := 120
	if s := os.Getenv("RSDD_STATE_FUZZ_N"); s != "" {
		v, err := strconv.Atoi(s)
		if err != nil {
			t.Fatal(err)
		}
		n = v
	}
	kinds := map[string]bool{}
	rcs := map[int]int{}
	for i := 0; i < n; i++ {
		r := rand.New(rand.NewSource(int64(1000 + i)))
		d := filepath.Join(t.TempDir(), "corpus")
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		args := genCorpus(t, r, d)
		o := sdCompare(t, fmt.Sprintf("seed %d", 1000+i), d, args...)
		rcs[o.RC]++
		for _, l := range strings.Split(o.Stdout+o.Stderr, "\n") {
			if f := strings.Fields(l); len(f) > 1 && (f[0] == "FAIL" || f[0] == "WARN" || f[0] == "INFO" || f[0] == "WARN:") {
				kinds[strings.Join(f[:2], " ")+" "+strings.Join(f[2:min(len(f), 4)], " ")] = true
			}
		}
	}
	// non-vacuity: a generator that stopped producing findings would pass every comparison trivially
	if n >= 100 && (len(kinds) < 40 || rcs[0] == 0 || rcs[1] == 0) {
		t.Errorf("the generator exercised only %d finding kinds, exit codes %v: it no longer covers the checks", len(kinds), rcs)
	}
	t.Logf("%d runs, exit codes %v, %d distinct finding kinds", n, rcs, len(kinds))
}
