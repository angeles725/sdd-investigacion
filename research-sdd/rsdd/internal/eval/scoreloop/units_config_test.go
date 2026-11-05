package scoreloop

import (
	"math"
	"math/big"
	"strings"
	"testing"
)

// Guard-to-test table:
//   envOr empty-is-unset ........................ TestLoadConfigDefaults
//   parseCount decimal, leading zeros, huge ...... TestParseCount
//   loadConfig order and messages ................ TestLoadConfigErrors
//   regexp validation floor and message .......... TestLoadConfigRegexpErrors
//   weigh region cut, groups, cap, saturation .... TestWeigh, TestIDRegion, TestSatWeight, TestTotalWeight

func envMap(kv ...string) func(string) string {
	m := envOf(kv...)
	return func(k string) string { return m[k] }
}

func TestLoadConfigDefaults(t *testing.T) {
	c, problem := loadConfig(envMap())
	if problem != "" || c.GraceMin != 10 || c.RangeCap.Cmp(big.NewInt(50)) != 0 || c.OperatorJQ != "" || c.CompactJQ != "" || c.StatusEnv != "" {
		t.Fatalf("defaults: %+v, %q", c, problem)
	}
	if !c.Question.MatchString("Shall I go") || !c.StopToken.MatchString("STOP: x") || !c.BlockCommit.MatchString("block(x): B1") {
		t.Error("default expressions do not match their documented forms")
	}
	c, problem = loadConfig(envMap("RSDD_C4_AFTER_STOP_GRACE", "", "RSDD_BLOCK_RANGE_CAP", "", "RSDD_BLOCK_ID_REGEX", ""))
	if problem != "" || c.GraceMin != 10 || c.RangeCap.Int64() != 50 {
		t.Errorf("an empty variable is unset: %+v, %q", c, problem)
	}
	c, _ = loadConfig(envMap("RSDD_OPERATOR_INPUT_JQ", ".a", "RSDD_COMPACT_JQ", ".b", "RSDD_STATUS_SCRIPT", "/x/s.sh", "RSDD_C4_AFTER_STOP_GRACE", "3", "RSDD_BLOCK_RANGE_CAP", "7"))
	if c.OperatorJQ != ".a" || c.CompactJQ != ".b" || c.StatusEnv != "/x/s.sh" || c.GraceMin != 3 || c.RangeCap.Int64() != 7 {
		t.Errorf("overrides: %+v", c)
	}
}

func TestParseCount(t *testing.T) {
	for in, want := range map[string]int64{"0": 0, "7": 7, "010": 10, "0050": 50} {
		if n, ok := parseCount(in); !ok || n.Int64() != want {
			t.Errorf("parseCount(%q) = %v, %v; want %d", in, n, ok, want)
		}
	}
	if n, ok := parseCount("99999999999999999999999"); !ok || n.IsInt64() {
		t.Errorf("a huge count must parse as a big integer: %v %v", n, ok)
	}
	for _, in := range []string{"", "-1", "1.5", "abc", " 1", "1 ", "+1", "0x10"} {
		if _, ok := parseCount(in); ok {
			t.Errorf("parseCount(%q) accepted", in)
		}
	}
}

func TestLoadConfigErrors(t *testing.T) {
	_, p := loadConfig(envMap("RSDD_C4_AFTER_STOP_GRACE", "abc"))
	if want := "score-loop-transcript.sh: RSDD_C4_AFTER_STOP_GRACE must be a non-negative integer (minutes), got: abc"; p != want {
		t.Errorf("grace message %q", p)
	}
	_, p = loadConfig(envMap("RSDD_BLOCK_RANGE_CAP", "-2"))
	if want := "score-loop-transcript.sh: RSDD_BLOCK_RANGE_CAP must be a non-negative integer, got: -2"; p != want {
		t.Errorf("cap message %q", p)
	}
	if _, p = loadConfig(envMap("RSDD_C4_AFTER_STOP_GRACE", "x", "RSDD_BLOCK_RANGE_CAP", "y")); !strings.Contains(p, "RSDD_C4_AFTER_STOP_GRACE") {
		t.Errorf("the grace is checked first: %q", p)
	}
	if c, p := loadConfig(envMap("RSDD_C4_AFTER_STOP_GRACE", "99999999999999999999999")); p != "" || c.GraceMin != math.MaxInt64 {
		t.Errorf("a huge grace saturates: %d %q", c.GraceMin, p)
	}
}

func TestLoadConfigRegexpErrors(t *testing.T) {
	for _, c := range []struct{ env, val, want string }{
		{"RSDD_BLOCK_COMMIT_REGEX", "^(a", "RSDD_BLOCK_COMMIT_REGEX is not a valid regular expression: "},
		{"RSDD_BLOCK_ID_REGEX", "B(", "RSDD_BLOCK_ID_REGEX is not a valid regular expression: "},
		{"RSDD_QUESTION_REGEX", "(", "RSDD_QUESTION_REGEX is not a valid regular expression: "},
		{"RSDD_STOP_TOKEN_REGEX", "[", "RSDD_STOP_TOKEN_REGEX is not a valid regular expression: "},
		{"RSDD_BLOCK_COMMIT_REGEX", "^a(b)$", "RSDD_BLOCK_COMMIT_REGEX needs at least 2 capture groups (prefix, text after the colon), got 1"},
		{"RSDD_BLOCK_COMMIT_REGEX", "^ab$", "RSDD_BLOCK_COMMIT_REGEX needs at least 2 capture groups (prefix, text after the colon), got 0"},
		{"RSDD_BLOCK_ID_REGEX", "B[0-9]+", "RSDD_BLOCK_ID_REGEX needs at least 1 capture group (the start block number), got 0"},
	} {
		_, p := loadConfig(envMap(c.env, c.val))
		if !strings.HasPrefix(p, "score-loop-transcript.sh: "+c.want) {
			t.Errorf("%s=%q: message %q, want prefix %q", c.env, c.val, p, c.want)
		}
	}
	// Exactly the floor passes: two groups for the commit expression, one for the id.
	if _, p := loadConfig(envMap("RSDD_BLOCK_COMMIT_REGEX", "^(a)(b)$", "RSDD_BLOCK_ID_REGEX", "B([0-9]+)")); p != "" {
		t.Errorf("floor rejected: %q", p)
	}
}

func TestQuestionRegexpFoldsCase(t *testing.T) {
	c, _ := loadConfig(envMap("RSDD_QUESTION_REGEX", "maybe"))
	if !c.Question.MatchString("MAYBE") || c.StopToken.MatchString("stop:") {
		t.Error("the question expression folds case; the stop expression does not")
	}
}

func TestIDRegion(t *testing.T) {
	for in, want := range map[string]string{
		"B1 x": "B1 x", "B1 (B2)": "B1 ", "B1 — B2": "B1 ", "B1 → B2": "B1 ", "(B1)": "", "a → b — c (d": "a ",
		"a (b — c": "a ", "a — b (c": "a ", "": "",
	} {
		if got := idRegion(in); got != want {
			t.Errorf("idRegion(%q) = %q, want %q", in, got, want)
		}
	}
}

func cfgWith(t *testing.T, kv ...string) *Config {
	t.Helper()
	c, p := loadConfig(envMap(kv...))
	if p != "" {
		t.Fatal(p)
	}
	return &c
}

func TestWeigh(t *testing.T) {
	c := cfgWith(t)
	for _, k := range []struct {
		subject     string
		matched     bool
		weight      int64
		implausible bool
	}{
		{"research(d): B1 x", true, 1, false}, {"block(d): B7", true, 1, false}, {"docs(d): B1", false, 0, false},
		{"research(d): no id", false, 0, false}, {"research(d): B1-B3", true, 3, false}, {"research(d): B3-B3", true, 1, false},
		{"research(d): B5-B3", true, 1, false}, {"research(d): B1-B51", true, 51, false}, {"research(d): B1-B52", true, 1, true},
		{"research(d): B007-B009", true, 3, false}, {"research(d): note (B1-B30)", false, 0, false}, {"research(d): B2 — B1-B30", true, 1, false},
		{"research(d): B99999999999999999999-B99999999999999999999", true, 1, false},
	} {
		w := c.weigh(k.subject)
		if w.matched != k.matched || w.weight != k.weight || w.implausible != k.implausible {
			t.Errorf("weigh(%q) = %+v, want matched=%v weight=%d implausible=%v", k.subject, w, k.matched, k.weight, k.implausible)
		}
	}
	if w := c.weigh("research(d): B0007-B0300 x"); w.start != "0007" || w.end != "0300" {
		t.Errorf("the numbers keep their leading zeros: %+v", w)
	}
	if w := cfgWith(t, "RSDD_BLOCK_RANGE_CAP", "0").weigh("research(d): B1-B2"); !w.implausible || w.weight != 1 {
		t.Errorf("cap 0: %+v", w)
	}
	if w := cfgWith(t, "RSDD_BLOCK_RANGE_CAP", "0").weigh("research(d): B2-B2"); w.implausible || w.weight != 1 {
		t.Errorf("cap 0, equal ends: %+v", w)
	}
}

func TestWeighOverrides(t *testing.T) {
	c := cfgWith(t, "RSDD_BLOCK_ID_REGEX", `([a-z]+)(-([a-z]+))?`)
	if w := c.weigh("research(d): abc"); w.matched {
		t.Errorf("a non-numeric capture is not a block: %+v", w)
	}
	c = cfgWith(t, "RSDD_BLOCK_ID_REGEX", `#([0-9]+)`)
	if w := c.weigh("research(d): #4 and #9"); !w.matched || w.weight != 1 || w.start != "4" || w.end != "4" {
		t.Errorf("an id expression without a range group: %+v", w)
	}
	c = cfgWith(t, "RSDD_BLOCK_ID_REGEX", `#([0-9]+)(-#([0-9]*))?`)
	if w := c.weigh("research(d): #4-#"); !w.matched || w.end != "4" {
		t.Errorf("an empty end group falls back to the start: %+v", w)
	}
	c = cfgWith(t, "RSDD_BLOCK_COMMIT_REGEX", `^(x)\(a\): (.*)$`)
	if w := c.weigh("x(a): B2"); !w.matched {
		t.Errorf("commit expression override: %+v", w)
	}
	if w := c.weigh("research(a): B2"); w.matched {
		t.Errorf("the override replaces the default: %+v", w)
	}
}

func TestWeighTwoGroupIDExpression(t *testing.T) {
	// Exactly two capture groups: the range-end group is absent, so the end is the start (a mutant reading group 3 panics).
	c := cfgWith(t, "RSDD_BLOCK_ID_REGEX", `#([0-9]+)(-x)?`)
	if w := c.weigh("research(d): #4-x"); !w.matched || w.start != "4" || w.end != "4" || w.weight != 1 {
		t.Errorf("two groups: %+v", w)
	}
}

func TestSatWeight(t *testing.T) {
	huge, _ := new(big.Int).SetString("99999999999999999999", 10)
	for _, k := range []struct {
		span *big.Int
		want int64
	}{
		{big.NewInt(0), 1}, {big.NewInt(49), 50}, {big.NewInt(math.MaxInt64 - 1), math.MaxInt64},
		{big.NewInt(math.MaxInt64), math.MaxInt64}, {huge, math.MaxInt64},
	} {
		if got := satWeight(k.span); got != k.want {
			t.Errorf("satWeight(%v) = %d, want %d", k.span, got, k.want)
		}
	}
}

func TestTotalWeight(t *testing.T) {
	if got := totalWeight(nil); got != 0 {
		t.Errorf("empty: %d", got)
	}
	if got := totalWeight([]blockEntry{{1, 3}, {2, 1}, {3, 5}}); got != 9 {
		t.Errorf("sum: %d", got)
	}
}
