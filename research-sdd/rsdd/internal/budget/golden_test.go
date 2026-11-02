package budget

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Goldens: the outputs the script printed before the port, frozen as fixtures/verify-session-budget/_frozen/*.out
// with the fixture directory written @FIX@. They pin the report byte for byte without running the old script, so
// they stay meaningful after testdata/legacy is retired.

func TestFrozenGoldens(t *testing.T) {
	sb := newSbx(t)
	fix, err := filepath.EvalSymlinks(sb.fix)
	if err != nil {
		t.Fatal(err)
	}
	needsSandbox := map[string]bool{"mixed": true, "sources": true, "matchers": true, "newline": true, "utf8": true, "over": true, "partialmix": true, "fresh": true}
	frozen, err := filepath.Glob(filepath.Join(fixturesRel, "_frozen", "*.out"))
	if err != nil || len(frozen) == 0 {
		t.Fatalf("no frozen goldens under %s (a golden directory with no case FAILS): %v", fixturesRel, err)
	}
	for _, g := range frozen {
		name := strings.TrimSuffix(filepath.Base(g), ".out")
		t.Run(name, func(t *testing.T) {
			if needsSandbox[name] {
				needBwrap(t)
			}
			want, err := os.ReadFile(g)
			if err != nil {
				t.Fatal(err)
			}
			o := sb.golang(sb.environ(), filepath.Join(fix, name))
			got := strings.ReplaceAll(o.stdout, fix, "@FIX@")
			if got != string(want) || o.rc != 0 || o.stderr != "" {
				t.Errorf("%s differs from the frozen output (rc=%d stderr=%q):\n--- frozen\n%s--- go\n%s", name, o.rc, o.stderr, want, got)
			}
		})
	}
}

// The numbers the old bash suite asserted, case by case, now as Go assertions on the Go command alone.
func TestKnownNumbers(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	run := func(name string, extra ...string) string {
		o := sb.golang(sb.environ(extra...), sb.target(name))
		if o.rc != 0 || o.stderr != "" {
			t.Errorf("%s: rc=%d stderr=%q (findings are WARN-only: exit 0)", name, o.rc, o.stderr)
		}
		return o.stdout
	}
	for _, c := range []struct{ fixture, re, what string }{
		{"mixed", `hook\[1\] chars=500 status=ok`, "a plain 500-char hook"},
		{"mixed", `hook\[2\] chars=10500 status=TRUNCATED`, "10,500 chars is TRUNCATED"},
		{"mixed", `hook\[3\] chars=500 status=ok`, "JSON additionalContext+systemMessage counted (300+200)"},
		{"mixed", `hook\[4\] chars=5 status=ok`, "a writing hook is still measured"},
		{"mixed", `aggregate: 11505 chars .*OVER BUDGET`, "aggregate flagged OVER BUDGET"},
		{"over", `aggregate: 9000 chars .*OVER BUDGET`, "3 x 3000 is over budget with nothing truncated"},
		{"sources", `aggregate\[startup\]: 500 chars .* OK`, "startup total"},
		{"sources", `aggregate\[resume\]: 5500 chars .* OK`, "resume total"},
		{"sources", `aggregate\[compact\]: 9100 chars .*OVER BUDGET`, "compact total"},
		{"sources", `aggregate: 9100 chars .*OVER BUDGET worst-source=compact`, "the worst source decides"},
		{"newline", `aggregate\[startup\]: 10 chars`, "a command with embedded newlines is one hook"},
		{"timeouts", `hook\[1\] chars=0 status=timed-out\(hook timeout 1s\)`, "a hook outliving its own timeout counts 0"},
		{"timeouts", `state: ok \(1 hook runs, 0 truncated, 1 timed-out\)`, "counted on the state line"},
		{"matchers", `aggregate\[startup\]: 500 chars`, "regex ^start is unanchored"},
		{"matchers", `aggregate\[resume\]: 300 chars`, "list 'startup, resume' with a comma and spaces"},
		{"matchers", `aggregate\[fork\]: 50 chars`, "exact 'fork'"},
		{"matchers", `source clear: \(no matching`, "exact 'start' does not match 'startup'"},
		{"partialmix", `aggregate: 9000 chars .*OVER BUDGET \(partial: 1 degraded in startup\) worst-source=compact`, "partial even when the worst source is clean"},
		{"utf8", `hook\[1\] chars=3 status=ok`, "three accented characters count as 3"},
	} {
		if out := run(c.fixture); !has(out, c.re) {
			t.Errorf("%s (%s): no line /%s/ in\n%s", c.fixture, c.what, c.re, out)
		}
	}
	if out := run("sources"); strings.Count(blockOf(out, "startup"), "hook[") != 2 {
		t.Errorf("an identical command under two entries must run once within a source:\n%s", out)
	}
	if out := run("matchers"); has(out, `exact7000|chars=7000`) {
		t.Errorf("exact 'start' must NOT match 'startup' (its 7000-char hook never runs):\n%s", out)
	}
	if out := run("over"); has(out, `TRUNCATED`) {
		t.Errorf("no single hook is over 10,000:\n%s", out)
	}
	if out := run("fresh"); strings.Count(out, "chars=5 status=ok") != 5 {
		t.Errorf("each of the five sources must see a fresh .claude copy:\n%s", out)
	}
	deg := run("degraded", "RSDD_BUDGET_HOOK_TIMEOUT=1")
	for _, re := range []string{`hook\[1\] chars=100 status=ok`, `hook\[2\] .*status=degraded\(timeout`, `hook\[3\] .*status=degraded\(exit 1`, `hook\[4\] .*status=degraded\(`,
		`aggregate: 100 chars .*partial: 3 degraded`} {
		if !has(deg, re) {
			t.Errorf("degraded: no line /%s/ in\n%s", re, deg)
		}
	}
	if has(deg, `chars=0`) {
		t.Errorf("a degraded hook is never counted as 0 chars:\n%s", deg)
	}
	capped := run("capped", "RSDD_BUDGET_HOOK_TIMEOUT=1")
	if strings.Count(capped, "not re-run") != 4 || !has(capped, `partial: 5 degraded in startup,resume,clear,compact,fork`) {
		t.Errorf("a command that hit the script cap runs once and says 'not re-run' later:\n%s", capped)
	}
}

// blockOf returns the lines of one source's report.
func blockOf(out, src string) string {
	var b strings.Builder
	in := false
	for _, l := range strings.Split(out, "\n") {
		if l == "source "+src+":" {
			in = true
		}
		if in {
			b.WriteString(l + "\n")
			if strings.HasPrefix(l, "aggregate["+src+"]") {
				break
			}
		}
	}
	return b.String()
}
