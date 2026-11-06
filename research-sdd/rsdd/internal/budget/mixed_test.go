package budget

import (
	"strings"
	"testing"
)

func TestHookName(t *testing.T) {
	for cmd, want := range map[string]string{
		`"$CLAUDE_PROJECT_DIR/research-sdd/toolbelt/sweep-retros-hook.sh"`: "sweep-retros-hook",
		`bash /x/y/foo.sh --flag`: "foo",
		`echo hi`:                 "echo",
	} {
		if got := hookName(cmd); got != want {
			t.Errorf("hookName(%q) = %q, want %q", cmd, got, want)
		}
	}
}

// The worst mix is the SUM over hooks of max(normal, FailureCap): a failing hook costs the cap only when its normal
// context is smaller. Two hooks over the cap and one under, the small one first, middle and last.
func TestMixedIsSumOfMaxima(t *testing.T) {
	big1, small, big2 := reading{"big1", 2000, false}, reading{"small", 100, false}, reading{"big2", 1500, false}
	for pos, rs := range map[string][]reading{
		"first":  {small, big1, big2},
		"middle": {big1, small, big2},
		"last":   {big1, big2, small},
	} {
		line, total := mixedSourceLine("startup", rs)
		if total != 2000+800+1500 {
			t.Errorf("%s: total %d, want 4300 (sum of maxima)", pos, total)
		}
		for _, w := range []string{"mixed[startup]: 4300 chars (budget < 8000) mixed-verdict=OK", "normal total 3600", "all-fail 3 x 800 = 2400",
			"normal: big1 2000, big2 1500; cap 800: small"} {
			if !strings.Contains(line, w) {
				t.Errorf("%s: %q missing from %q", pos, w, line)
			}
		}
	}
}

func TestMixedLineShape(t *testing.T) {
	over := make([]reading, 9)
	for i := range over {
		over[i] = reading{"h", 1000, false}
	}
	line, total := mixedSourceLine("resume", over)
	if total != 9000 || !strings.Contains(line, "mixed-verdict=OVER") {
		t.Errorf("9 x 1000: total %d line %q", total, line)
	}
	// verify registry parses ^aggregate: and greps OVER BUDGET: the mixed lines must trigger neither.
	for _, l := range []string{line, mixedOverallLine(9000, "resume", 0)} {
		if strings.HasPrefix(l, "aggregate") || strings.Contains(l, "OVER BUDGET") {
			t.Errorf("mixed line collides with the normal-total parser: %q", l)
		}
	}
	if _, total := mixedSourceLine("clear", []reading{{"a", 800, false}}); total != 800 {
		t.Errorf("a hook exactly at the cap counts its normal 800, got %d", total)
	}
	if l, _ := mixedSourceLine("clear", []reading{{"a", 800, false}}); !strings.Contains(l, "normal: a 800; cap 800: none") {
		t.Errorf("at the cap is attributed to normal: %q", l)
	}
}

// A degraded hook has no measured normal size: the line is marked partial, never printed as if complete (§7).
func TestMixedPartialWhenDegraded(t *testing.T) {
	line, total := mixedSourceLine("startup", []reading{{"a", 2000, false}, {"b", 0, true}})
	if total != 2800 || !strings.Contains(line, "(partial: 1 degraded, counted at the cap)") {
		t.Errorf("degraded hook: total %d line %q", total, line)
	}
	if l, _ := mixedSourceLine("startup", []reading{{"a", 2000, false}}); strings.Contains(l, "partial") {
		t.Errorf("a fully measured source is not partial: %q", l)
	}
}

func TestMixedOverallLine(t *testing.T) {
	l := mixedOverallLine(7983, "startup", 0)
	for _, w := range []string{"mixed: 7983 chars (budget < 8000) mixed-verdict=OK worst-source=startup", "#2773", "reading", "not a bound"} {
		if !strings.Contains(l, w) {
			t.Errorf("%q missing from %q", w, l)
		}
	}
	if l := mixedOverallLine(7983, "startup", 2); !strings.Contains(l, "(partial: 2 degraded)") {
		t.Errorf("overall line must carry the partial mark: %q", l)
	}
	if p := piMixedLine(); !strings.HasPrefix(p, "mixed: ") || !strings.Contains(p, "7900") {
		t.Errorf("pi line: %q", p)
	}
}
