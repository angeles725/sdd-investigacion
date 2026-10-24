//go:build !nodiff

package grammar

import (
	"math/rand"
	"sort"
	"strings"
	"testing"
)

// markerParts are the fragments the synthetic marker lines are built from: every status, PARTIAL, shipped and
// DISMISSED form the readers distinguish, with their near misses.
var markerParts = [][]string{
	{"<!-- review-status: ", "<!--review-status:", "", "x <!-- REVIEW-STATUS: ", "review-status: "},
	{"applied", "Dismissed", "pending", "123", ""},
	{" · sha", " · PARTIAL", " ·PARTIAL1", " · Partial", " (PARTIAL)", " — note", " xPARTIAL", ""},
	{" — shipped: #1, #2", " · shipped: P1-P3 (x)", " shipped: Δ1 (#549), D1 (§20)", " · SHIPPED: x", " Shipped: P08-P10",
		" shipped: #1,,#2\t3", " shipped: P3-P1, 1-3", ""},
	{"; DISMISSED: #2 (reason; more)", "; DISMISSED: ;", "; DISMISSED: (only (nested) reason)", "; DEFERRED: #7; DISMISSED: 5",
		" dismissed: 3", " xDISMISSED: 9", "; DISMISSED: 4; DISMISSED: 1-2 --> DISMISSED: 8", "(DISMISSED: 6)", ""},
	{" -->", " --> PARTIAL", " -> x", " --> shipped: 9", ""},
}

// markerLines is a fixed sample of synthetic marker lines plus every fixture and vocabulary line that mentions a
// marker keyword.
func markerLines(t *testing.T) []string {
	t.Helper()
	set := map[string]bool{"": true}
	r := rand.New(rand.NewSource(1944))
	for i := 0; i < 600; i++ {
		var b strings.Builder
		for _, part := range markerParts {
			b.WriteString(part[r.Intn(len(part))])
		}
		set[b.String()] = true
	}
	markerKeywordLines(set, genVocab)
	markerKeywordLines(set, markerVocab)
	for _, p := range fixturePaths(t) {
		d, err := Read(p)
		if err != nil {
			t.Fatal(err)
		}
		markerKeywordLines(set, d.Raw)
	}
	out := make([]string, 0, len(set))
	for l := range set {
		out = append(out, l)
	}
	sort.Strings(out)
	return out
}

// idsOut renders an id list the way the bash helpers print it.
func idsOut(ids []string, err error) bashOut {
	if err != nil {
		return bashOut{rc: -1, stderr: err.Error()}
	}
	return bashOut{stdout: joinLines(ids)}
}

// lineModes maps a driver line mode to the Go rendering of the same call on one marker line.
var lineModes = map[string]func(line string) bashOut{
	"sfml":    func(l string) bashOut { return lineOut(StatusFromMarkerLine(l)) },
	"partial": func(l string) bashOut { return bashOut{rc: rcOf(MarkerIsPartial(l))} },
	// shipped_raw prints its (possibly empty) list line whenever the keyword matched.
	"shraw": func(l string) bashOut {
		if l == "" || grepO(l, reShippedList) == "" {
			return bashOut{}
		}
		return bashOut{stdout: ShippedRaw(l) + "\n"}
	},
	"shids": func(l string) bashOut { return idsOut(ShippedIDs(l)) },
	"dism": func(l string) bashOut {
		ids, malformed, err := dismissedIDs(l)
		if malformed {
			return bashOut{rc: 3}
		}
		return idsOut(ids, err)
	},
}

// TestDifferentialRowState asks every PARTIAL marker line (and a sample of the others) about six row ids. Bash
// forks about ten processes per call, so the non-partial lines are sampled 1 in 10.
func TestDifferentialRowState(t *testing.T) {
	var inputs []string
	for i, l := range markerLines(t) {
		if !MarkerIsPartial(l) && i%10 != 0 {
			continue
		}
		for _, rid := range []string{"1", "2", "5", "P2", "9", ""} {
			inputs = append(inputs, l+"\x1f"+rid)
		}
	}
	bash := bashBatch(t, "rowstate", inputs)
	seen := map[string]bool{}
	for i, in := range inputs {
		line, rid, _ := strings.Cut(in, "\x1f")
		got := bashOut{stdout: string(MarkerRowState(line, rid)) + "\n"}
		seen[bash[i].stdout] = true
		if got != bash[i] {
			t.Errorf("rowstate %q %q: go=%+v bash=%+v", line, rid, got, bash[i])
		}
	}
	if len(seen) < 5 {
		t.Errorf("rowstate: bash gave only %d of the 5 answers: the corpus misses a state", len(seen))
	}
	t.Logf("rowstate: %d (line, id) pairs, %d distinct answers", len(inputs), len(seen))
}

func TestDifferentialMarkerLines(t *testing.T) { checkLineModes(t, "synthetic", markerLines(t), true) }

// checkLineModes runs every line mode over lines (the id normaliser over their shipped lists, as the consumers
// feed it) on both sides. With requireSignal a mode with a single bash outcome fails as vacuous.
func checkLineModes(t *testing.T, label string, lines []string, requireSignal bool) {
	t.Helper()
	for mode, f := range lineModes {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			inputs := lines
			if mode == "shids" {
				inputs = shippedLists(lines)
			}
			bash := bashBatch(t, mode, inputs)
			distinct, bad := map[bashOut]bool{}, 0
			for i, in := range inputs {
				distinct[bash[i]] = true
				if got := f(in); got != bash[i] {
					if bad++; bad <= 5 {
						t.Errorf("%s %s %q:\n  go=%+v\nbash=%+v", label, mode, in, got, bash[i])
					}
				}
			}
			if requireSignal && len(distinct) < 2 {
				t.Errorf("%s %s: one bash outcome for all %d inputs: vacuous", label, mode, len(inputs))
			}
			t.Logf("%s %s: %d inputs, %d distinct bash outcomes", label, mode, len(inputs), len(distinct))
		})
	}
}

// markerKeywordLines keeps the lines of d that mention a marker keyword (review-status, shipped, DISMISSED).
func markerKeywordLines(set map[string]bool, lines []string) {
	for _, l := range lines {
		low := lower(l)
		if strings.Contains(low, "review-status") || strings.Contains(low, "shipped") || strings.Contains(l, "DISMISSED") {
			set[strings.TrimSuffix(l, "\r")] = true
		}
	}
}

// shippedLists is every non-empty ShippedRaw of lines, every DISMISSED segment text, and the id edges.
func shippedLists(lines []string) []string {
	set := map[string]bool{"": true, "P08-P10": true, "P3-P1": true, "##5": true, "#": true, "a,,b\tc": true,
		"(c) a": true, "x (unclosed": true, "P99999999999999999999-P99999999999999999999": true, "A1-B3": true}
	for _, l := range lines {
		set[ShippedRaw(l)] = true
		if _, seg, ok := strings.Cut(l, "DISMISSED:"); ok {
			set[seg] = true
		}
	}
	out := make([]string, 0, len(set))
	for s := range set {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
