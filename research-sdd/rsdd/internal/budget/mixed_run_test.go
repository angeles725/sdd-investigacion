package budget

import "testing"

// The mixed lines on a real (sandboxed) run, raw: no helper strips them here.
func TestMixedLinesOnRun(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	// "mixed" fixture: hooks of 500, 10500, 500 and 5 characters -> 800 + 10500 + 800 + 800.
	o := sb.golangRaw(sb.environ(), sb.target("mixed"))
	for _, re := range []string{
		`(?m)^mixed\[startup\]: 12900 chars \(budget < 8000\) mixed-verdict=OVER \(normal total 11505, all-fail 4 x 800 = 3200\)`,
		`(?m)^mixed: 12900 chars \(budget < 8000\) mixed-verdict=OVER worst-source=startup`,
	} {
		if !has(o.stdout, re) {
			t.Errorf("no line /%s/ in\n%s", re, o.stdout)
		}
	}
	// A degraded hook makes the line partial (it is not counted as 0).
	d := sb.golangRaw(sb.environ("RSDD_BUDGET_HOOK_TIMEOUT=1"), sb.target("degraded"))
	if !has(d.stdout, `(?m)^mixed\[startup\]: 3200 chars .*\(partial: 3 degraded, counted at the cap\)`) || !has(d.stdout, `(?m)^mixed: 3200 chars .*\(partial: 3 degraded\)`) {
		t.Errorf("degraded run: partial mixed lines missing in\n%s", d.stdout)
	}
	// pi: the extension caps the whole injected string itself; nothing is computed, and it says so.
	if p := sb.golangRaw(sb.piEnv(), "--harness", "pi", sb.target("pi-card")); !has(p.stdout, `(?m)^mixed: .*7900`) || has(p.stdout, `mixed\[`) {
		t.Errorf("pi run: want the one bounded-by-the-extension line and no per-source line in\n%s", p.stdout)
	}
}
