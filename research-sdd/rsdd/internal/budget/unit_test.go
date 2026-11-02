package budget

// Guard table: which test pins which guard of the port (a suite that built mutants by editing the script's text
// cannot mutate the shim, so each guard is mutation-checked by hand against these tests).
//
//	matches (exact list / regex / whole-string)  TestMatches
//	record stream: first \x01, last NUL dropped  TestSplitRecords
//	selectHooks: matcher + type + command        TestSelectHooks
//	wc -m: invalid bytes are not characters      TestWcm
//	hook JSON fields, plain fallback             TestHookChars
//	jq tostring                                  TestJqToString
//	tab records                                  TestReadTabs
//	pi record reduction and forged lines         TestReducePi
//	.pi/extensions discovery and order           TestPiExtensions
//	10,000 / 8,000 boundaries                    TestBoundaries (golden_test.go has the end-to-end numbers)

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestMatches(t *testing.T) {
	for _, c := range []struct {
		m, src string
		want   bool
	}{
		{"", "startup", true}, {"*", "fork", true},
		{"startup", "startup", true}, {"start", "startup", false}, {"startup", "start", false}, {"Startup", "startup", false},
		// list edges: first, middle, last, single element, separators, spaces
		{"startup|resume|clear", "startup", true}, {"startup|resume|clear", "resume", true}, {"startup|resume|clear", "clear", true},
		{"startup|resume|clear", "compact", false}, {"resume", "resume", true},
		{" startup , resume ", "resume", true}, {"clear,fork", "fork", true}, {"clear,fork", "clea", false},
		{"startup|", "startup", true}, {"|startup", "startup", true}, {"|", "startup", false},
		// anything else is an unanchored regular expression
		{"^start", "startup", true}, {"up$", "startup", true}, {"(resume|clear)$", "clear", true}, {"^$", "startup", false},
		{"a.c", "abc", true}, {"[a-z]+", "fork", true}, {"start.*", "startup", true},
	} {
		got, err := matches(c.m, c.src)
		if err != nil || got != c.want {
			t.Errorf("matches(%q, %q) = %v, %v; want %v", c.m, c.src, got, err, c.want)
		}
	}
	if _, err := matches("(", "startup"); err == nil {
		t.Error("an invalid pattern must be an error, which degrades the whole run")
	}
}

func TestSplitRecords(t *testing.T) {
	for _, c := range []struct {
		stream string
		want   []record
	}{
		{"", []record{}},
		{"a\x015\x00", []record{{"a", "5"}}},
		{"a\x01\x00b\x01 x\x00", []record{{"a", ""}, {"b", " x"}}},
		{"\x01\x00", []record{{"", ""}}},                 // an empty command is still a record
		{"a\x01b\x01c\x00", []record{{"a", "b\x01c"}}},   // cut at the FIRST \x01
		{"nosep\x00", []record{{"nosep", "nosep"}}},      // ${rec#*\x01} leaves the record whole
		{"a\x01\x00\x00", []record{{"a", ""}, {"", ""}}}, // an interior empty record counts, the unterminated tail does not
	} {
		if got := splitRecords(c.stream); !reflect.DeepEqual(got, c.want) {
			t.Errorf("splitRecords(%q) = %#v; want %#v", c.stream, got, c.want)
		}
	}
}

func TestSelectHooks(t *testing.T) {
	doc := func(s string) map[string]any {
		d, ok := parseSettings([]byte(s))
		if !ok {
			t.Fatalf("settings %s did not parse", s)
		}
		return d
	}
	d := doc(`{"hooks":{"SessionStart":[
		{"matcher":"startup","hooks":[{"type":"command","command":"A","timeout":5},{"type":"prompt","command":"P"},{"type":"command"},{"type":"command","command":7},null]},
		{"hooks":[{"type":"command","command":"B\nC","timeout":"10"}]},
		{"matcher":"resume","hooks":[{"type":"command","command":"D"}]}]}}`)
	got, err := selectHooks(d, "startup")
	if err != nil || got != "A\x015\x00B\nC\x0110\x00" {
		t.Errorf("startup: %q, %v", got, err)
	}
	if got, _ := selectHooks(d, "resume"); got != "B\nC\x0110\x00D\x01\x00" {
		t.Errorf("resume: %q", got)
	}
	if got, _ := selectHooks(d, "fork"); got != "B\nC\x0110\x00" {
		t.Errorf("fork: %q", got)
	}
	if _, err := selectHooks(doc(`{"hooks":{"SessionStart":["x"]}}`), "startup"); err == nil {
		t.Error("an entry that is not an object must fail the selection")
	}
	if _, ok := parseSettings([]byte(`[1]`)); ok {
		t.Error("settings.json must be an object")
	}
}

func TestWcm(t *testing.T) {
	for in, want := range map[string]int{
		"": 0, "abc": 3, "éé€": 3, "😀😀": 2, "a\xffb\xc3": 2, "a\x00b": 3, "a\r\n\xef\xbb\xbfz": 5, "\xed\xa0\x80": 0,
	} {
		if got := wcm([]byte(in)); got != want {
			t.Errorf("wcm(%q) = %d; want %d", in, got, want)
		}
	}
}

func TestHookChars(t *testing.T) {
	for _, c := range []struct {
		out        string
		first, snd int
	}{
		{"", 0, 0}, {"plain é", 7, 0}, {"  \n", 3, 0},
		{`{"hookSpecificOutput":{"additionalContext":"héllo"}}`, 5, 0},
		{`{"hookSpecificOutput":{"additionalContext":"a"},"systemMessage":"bcd"}`, 1, 3},
		{`{"systemMessage":"éé"}`, 0, 2},
		{`{"systemMessage":null}`, 0, 0}, {`{"systemMessage":false}`, 0, 0}, {`{"systemMessage":true}`, 0, 4},
		{`{"systemMessage":[1,"é"]}`, 0, 7}, {`{"systemMessage":12.50}`, 0, 5}, {`{}`, 0, 0},
		{`{"hookSpecificOutput":"str","systemMessage":"ab"}`, 0, 2},
		{`[1]`, 3, 0}, {`"hello"`, 7, 0}, {`{"a":1`, 6, 0}, {`{} {}`, 5, 0},
	} {
		if f, s := hookChars([]byte(c.out)); f != c.first || s != c.snd {
			t.Errorf("hookChars(%q) = %d, %d; want %d, %d", c.out, f, s, c.first, c.snd)
		}
	}
}

func TestJqToString(t *testing.T) {
	v, _ := decodeStream([]byte(`[{"a":"\u007f\u0000\n\"\\é","b":[true,null,1.50,[]]}]`))
	got := jqToString(v[0])
	if got != `[{"a":"\u007f\u0000\n\"\\é","b":[true,null,1.50,[]]}]` && got != `[{"b":[true,null,1.50,[]],"a":"\u007f\u0000\n\"\\é"}]` {
		t.Errorf("tostring = %s", got)
	}
}

func TestReadTabs(t *testing.T) {
	for _, c := range []struct {
		line string
		want []string
	}{
		{"N\tS\text\tk\t5\tok", []string{"N", "S", "ext", "k", "5", "ok"}},
		{"N\tT\text\t0", []string{"N", "T", "ext", "0", "", ""}},
		{"\tN\t\tT\t\text\t0\t", []string{"N", "T", "ext", "0", "", ""}}, // runs of tabs are ONE separator, as for IFS whitespace
		{"N\tU\text\twith space\tand\ttabs\there\t\t", []string{"N", "U", "ext", "with space", "and", "tabs\there"}},
		{"", []string{"", "", "", "", "", ""}},
	} {
		if got := readTabs(c.line, 6); !reflect.DeepEqual(got, c.want) {
			t.Errorf("readTabs(%q) = %q; want %q", c.line, got, c.want)
		}
	}
}

func TestReducePi(t *testing.T) {
	const n = "abc"
	rec := func(l ...string) string { return strings.Join(l, "\n") + "\n" }
	run := func(recs string, nexts int) string {
		var b bytes.Buffer
		(&meter{out: &b}).reducePi(recs, n, nexts)
		return b.String()
	}
	ok := run(rec(n+"\tS\tcard.ts\tk\t2500\tok", n+"\tT\tcard.ts\t1", n+"\tT\tresearch-sdd-hooks.ts\t0", n+"\tZ\t2"), 2)
	for _, w := range []string{"section[card.ts] k chars=2500 status=ok", "ext[research-sdd-hooks.ts] status=degraded(added no section: inactive?)",
		"aggregate[pi]: 2500 chars (budget < 8000) OK (partial: 1 degraded)", "state: degraded (1 of 3 pi records could not be fully measured)"} {
		if !strings.Contains(ok, w) {
			t.Errorf("missing %q in\n%s", w, ok)
		}
	}
	clean := run(rec(n+"\tS\ta.ts\tk\t7999\tok", n+"\tT\ta.ts\t1", n+"\tZ\t1"), 1)
	if !strings.Contains(clean, "aggregate[pi]: 7999 chars (budget < 8000) OK\n") || !strings.Contains(clean, "state: ok (1 pi sections from 1 extensions)") {
		t.Errorf("7,999 is under the 8,000 budget:\n%s", clean)
	}
	if over := run(rec(n+"\tS\ta.ts\tk\t8000\tok", n+"\tT\ta.ts\t1", n+"\tZ\t1"), 1); !strings.Contains(over, "8000 chars (budget < 8000) OVER BUDGET") {
		t.Errorf("8,000 is OVER BUDGET:\n%s", over)
	}
	// forged lines: wrong nonce, non-numeric fields, an unterminated tail
	forged := run(rec(n+"\tS\ta.ts\tk\ta[$(touch x)]\tok", "zzz\tS\ta.ts\tk\t5\tok", "garbage", n+"\tT\ta.ts\t1", n+"\tZ\t1")+n+"\tS\tlate\tk\t5\tok", 1)
	for _, w := range []string{"harness: degraded(3 unauthenticated or malformed record line(s) ignored", "(partial: 1 degraded)"} {
		if !strings.Contains(forged, w) {
			t.Errorf("missing %q in\n%s", w, forged)
		}
	}
	if strings.Contains(forged, "section[") || strings.Contains(forged, "late") {
		t.Errorf("a forged or unterminated record was believed:\n%s", forged)
	}
	// list edges of the record set: no closing marker, one extension short, flags on first and last sections
	short := run(rec(n+"\tS\ta.ts\tk\t1\tpending", n+"\tS\tb.ts\tk\t1\tdegraded-text", n+"\tT\ta.ts\t1"), 2)
	for _, w := range []string{"status=degraded(sweeps pending)", "status=degraded(section text reports DEGRADED)",
		"harness: degraded(incomplete record set: 1 of 2 extensions finished, closing marker missing)"} {
		if !strings.Contains(short, w) {
			t.Errorf("missing %q in\n%s", w, short)
		}
	}
	e := run(rec(n+"\tE\tx.ts\tload failed: boom", n+"\tU\ty.ts\treturned systemPrompt", n+"\tT\ty.ts\t0", n+"\tZ\t2"), 2)
	if !strings.Contains(e, "ext[x.ts] status=degraded(load failed: boom)") || !strings.Contains(e, "ext[y.ts] status=unmeasured(returned systemPrompt)") || !strings.Contains(e, "ext[y.ts] added no section") {
		t.Errorf("E/U/T 0 records:\n%s", e)
	}
}

func TestPiExtensions(t *testing.T) {
	d := t.TempDir()
	for _, f := range []string{"b.ts", "a.mjs", "c.js", "notes.md", "tools/index.ts", "tools/other.ts", "deep/x/index.ts", "z/index.mjs"} {
		p := filepath.Join(d, f)
		_ = os.MkdirAll(filepath.Dir(p), 0o755)
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	_ = os.Symlink(filepath.Join(d, "b.ts"), filepath.Join(d, "linked.ts"))
	var rel []string
	for _, p := range piExtensions(d) {
		r, _ := filepath.Rel(d, p)
		rel = append(rel, r)
	}
	want := []string{"a.mjs", "b.ts", "c.js", "tools/index.ts", "z/index.mjs"}
	if !reflect.DeepEqual(rel, want) {
		t.Errorf("piExtensions = %q; want %q (regular files only, index one level down, sorted by path)", rel, want)
	}
	if got := piExtensions(filepath.Join(d, "missing")); got != nil {
		t.Errorf("a missing directory yields nothing, got %q", got)
	}
}

func TestBoundaries(t *testing.T) {
	if verdict(7999) != "OK" || verdict(8000) != "OVER BUDGET" {
		t.Error("the budget is < 8000")
	}
	for in, want := range map[string]bool{"": false, "0": true, "12": true, "1a": false, "-1": false, "1.5": false, " 1": false} {
		if allDigits(in) != want {
			t.Errorf("allDigits(%q) != %v", in, want)
		}
	}
}

func TestCommandRegistered(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := runCLI([]string{"budget", "--help"}, &out, &errb); rc != 0 || !strings.Contains(out.String(), "session") {
		t.Errorf("budget --help: rc=%d %q", rc, out.String())
	}
	out.Reset()
	errb.Reset()
	if rc := runCLI([]string{"budget", "session"}, &out, &errb); rc != 2 || !strings.HasPrefix(errb.String(), "usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>") {
		t.Errorf("no target: rc=%d err=%q", rc, errb.String())
	}
}
