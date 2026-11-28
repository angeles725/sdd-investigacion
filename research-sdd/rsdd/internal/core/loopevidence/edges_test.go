package loopevidence

import (
	"reflect"
	"strings"
	"testing"
)

// Exact-output pins for the shell word splitter and the transcript reader: the table tests in loopevidence_test.go
// only see their boolean verdicts, these see the values (words, trimmed lines, bounds) that the verdicts rest on.

func TestCommandSegmentsExactWords(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want [][]string
	}{
		{``, nil},
		{`;; && |`, nil},
		{`a b`, [][]string{{"a", "b"}}},
		{"a \t  b", [][]string{{"a", "b"}}},
		{`a;b&&c||d|e&f`, [][]string{{"a"}, {"b"}, {"c"}, {"d"}, {"e"}, {"f"}}},
		{"a\nb", [][]string{{"a"}, {"b"}}},
		{`(a b) c`, [][]string{{"a", "b"}, {"c"}}},
		{`'a b' "c d"`, [][]string{{"a b", "c d"}}},
		{`a\ b`, [][]string{{"a b"}}},
		{`a\;b`, [][]string{{"a;b"}}},
		{`"a\"b"`, [][]string{{`a"b`}}},
		{`'a\"b'`, [][]string{{`a\"b`}}},
		{`a '' b`, [][]string{{"a", "", "b"}}},
		{`a\`, [][]string{{`a\`}}},  // a trailing backslash is kept, not an out-of-range read
		{`"a\`, [][]string{{`a\`}}}, // and so is one inside an unterminated double quote
		{`"a b`, [][]string{{"a b"}}},
		{`x="a b" y`, [][]string{{"x=a b", "y"}}},
	} {
		if got := commandSegments(tc.in); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("commandSegments(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSkipOptions(t *testing.T) {
	for _, tc := range []struct {
		in       []string
		duration bool
		want     []string
	}{
		{nil, false, nil},
		{nil, true, nil},
		{[]string{"-a"}, false, []string{}},
		{[]string{"-a", "FOO=1", "cmd", "x"}, false, []string{"cmd", "x"}},
		{[]string{"cmd"}, false, []string{"cmd"}},
		{[]string{"20", "bash", "x"}, true, []string{"bash", "x"}},
		{[]string{"-s", "KILL", "20", "bash"}, true, []string{"20", "bash"}}, // an option value is taken for the duration: documented limit
		{[]string{"20"}, true, []string{}},
	} {
		got := skipOptions(tc.in, tc.duration)
		if len(got) != len(tc.want) || (len(got) > 0 && !reflect.DeepEqual(got, tc.want)) {
			t.Errorf("skipOptions(%q, %v) = %q, want %q", tc.in, tc.duration, got, tc.want)
		}
	}
}

func TestIsCommandFlag(t *testing.T) {
	for w, want := range map[string]bool{"-c": true, "-lc": true, "-ec": true, "-xc": true, "-l": false, "-": false, "--c": false, "-cz": false, "c": false, "": false, "-o": false} {
		if got := isCommandFlag(w); got != want {
			t.Errorf("isCommandFlag(%q) = %v, want %v", w, got, want)
		}
	}
}

func TestRunsStatusDegenerateCommands(t *testing.T) {
	// words run out at every stage: none of these may panic or count
	for _, c := range []string{"bash", "bash -x", "bash -c", "sh -lc", "nohup", "env FOO=1", "timeout 5", "time", "FOO=1", "rsdd", "rsdd status", "research-sdd-status.sh", "exec"} {
		if runsStatus(c, "") {
			t.Errorf("runsStatus(%q) = true", c)
		}
	}
	// assignments after a wrapper's duration are skipped too
	for _, c := range []string{`timeout 5 FOO=1 bash x/research-sdd-status.sh /t --next`, `FOO=1 nohup BAR=2 research-sdd-status.sh /t --emit-token`, `bash -x x/research-sdd-status.sh /t --next`, `rsdd status /t --emit-token`} {
		if !runsStatus(c, "") {
			t.Errorf("runsStatus(%q) = false", c)
		}
	}
	for _, c := range []string{`rsdd statusx /t --next`, `rsdd verify status --next`, `rsdd-status /t --next`, `bash x/research-sdd-status.sh /t --nextx`} {
		if runsStatus(c, "") {
			t.Errorf("runsStatus(%q) = true", c)
		}
	}
}

func TestRunsStatusFollowsBashCNestingToADepthBound(t *testing.T) {
	wrap := func(cmd string) string {
		return `bash -c "` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(cmd) + `"`
	}
	cmd := `bash s/research-sdd-status.sh /t --next`
	for depth := 0; depth <= maxShellDepth+2; depth++ {
		want := depth <= maxShellDepth
		if got := runsStatus(cmd, ""); got != want {
			t.Errorf("%d nested bash -c: runsStatus = %v, want %v (%q)", depth, got, want, cmd)
		}
		cmd = wrap(cmd)
	}
}

func TestTrimEOL(t *testing.T) {
	for in, want := range map[string]string{"": "", "a": "a", "a\n": "a", "a\r\n": "a", "a\r": "a", "\n": "", "\r\n": "", "a\n\n": "a", "a\rb\n": "a\rb"} {
		if got := string(trimEOL([]byte(in))); got != want {
			t.Errorf("trimEOL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestExcerptBound(t *testing.T) {
	if got := excerpt(strings.Repeat("a", maxExcerpt)); got != strings.Repeat("a", maxExcerpt) {
		t.Errorf("a string of exactly %d bytes was cut: %d", maxExcerpt, len(got))
	}
	if got, want := excerpt(strings.Repeat("a", maxExcerpt+1)), strings.Repeat("a", maxExcerpt)+"…"; got != want {
		t.Errorf("excerpt over the bound = %d bytes, want %d", len(got), len(want))
	}
	long := bash("bash s/research-sdd-status.sh /t --next #" + strings.Repeat("x", 500))
	if ev, ok := Classify([]byte(long), Options{}); !ok || !strings.HasSuffix(ev.Detail, "…") || len(ev.Detail) > maxExcerpt+len("…") {
		t.Errorf("long command evidence detail = %q", ev.Detail)
	}
}

// lineOfLen is a status-run transcript line of exactly n bytes.
func lineOfLen(t *testing.T, n int) string {
	t.Helper()
	base := len(bash("bash s/research-sdd-status.sh /t --next #"))
	if n < base {
		t.Fatalf("n=%d below the base line of %d bytes", n, base)
	}
	l := bash("bash s/research-sdd-status.sh /t --next #" + strings.Repeat("x", n-base))
	if len(l) != n {
		t.Fatalf("line is %d bytes, want %d", len(l), n)
	}
	return l
}

func TestScanReaderLineBoundIsExact(t *testing.T) {
	const max = 300
	for _, eol := range []string{"\n", "\r\n", ""} {
		for _, tc := range []struct {
			n        int
			found    bool
			oversize int
		}{{max - 1, true, 0}, {max, true, 0}, {max + 1, false, 1}, {max + 2, false, 1}, {max + 3, false, 1}} {
			sc, err := ScanReader(strings.NewReader(lineOfLen(t, tc.n)+eol), Options{MaxLineBytes: max})
			if err != nil || sc.Found != tc.found || sc.Oversize != tc.oversize || sc.Lines != 1 {
				t.Errorf("line of %d bytes + %q: %+v err=%v, want found=%v oversize=%d", tc.n, eol, sc, err, tc.found, tc.oversize)
			}
		}
	}
}

func TestScanReaderLinesLongerThanTheReadBuffer(t *testing.T) {
	const big = 150 << 10 // more than two 64 KiB reads
	ok := bash("bash s/research-sdd-status.sh /t --next")
	filler := `{"type":"user","message":{"content":"` + strings.Repeat("y", big) + `"}}`
	// inspected when the bound allows it (a chunked line is reassembled), a no-evidence line is counted, not dropped
	sc, err := ScanReader(strings.NewReader(filler+"\n"+lineOfLen(t, big)+"\n"), Options{MaxLineBytes: 2 * big})
	if err != nil || !sc.Found || sc.Lines != 2 || sc.Oversize != 0 {
		t.Errorf("reassembled long lines: %+v err=%v", sc, err)
	}
	// over the bound: counted once however many reads it took, the next line is still read
	sc, err = ScanReader(strings.NewReader(filler+"\n"+filler+"\n"+ok+"\n"), Options{MaxLineBytes: 1000})
	if err != nil || !sc.Found || sc.Lines != 3 || sc.Oversize != 2 {
		t.Errorf("over-bound long lines: %+v err=%v", sc, err)
	}
	// an over-bound last line with no newline is still a counted line
	sc, _ = ScanReader(strings.NewReader(filler), Options{MaxLineBytes: 1000})
	if sc.Found || sc.Lines != 1 || sc.Oversize != 1 {
		t.Errorf("unterminated over-bound line: %+v", sc)
	}
	// a long line that does carry the evidence, unterminated
	sc, _ = ScanReader(strings.NewReader(lineOfLen(t, big)), Options{MaxLineBytes: 2 * big})
	if !sc.Found || sc.Lines != 1 {
		t.Errorf("unterminated long evidence line: %+v", sc)
	}
}

func TestScanReaderDefaultBoundAndBlankLines(t *testing.T) {
	sc, _ := ScanReader(strings.NewReader("\n\n"+lineOfLen(t, 1000)+"\n"), Options{})
	if !sc.Found || sc.Lines != 3 || sc.Oversize != 0 {
		t.Errorf("blank lines are lines and the default bound admits 1000 bytes: %+v", sc)
	}
	sc, _ = ScanReader(strings.NewReader("\n"), Options{})
	if sc.Found || sc.Lines != 1 {
		t.Errorf("a lone newline is one empty line, not an empty transcript: %+v", sc)
	}
}

type failingReader struct{}

func (failingReader) Read([]byte) (int, error) { return 0, errBoom }

var errBoom = &boom{}

type boom struct{}

func (*boom) Error() string { return "boom" }

func TestScanReaderReadErrorIsUnreadable(t *testing.T) {
	if _, err := ScanReader(failingReader{}, Options{}); err == nil || !strings.Contains(err.Error(), "unreadable") || !strings.Contains(err.Error(), "boom") {
		t.Errorf("a failing reader: %v", err)
	}
}

func TestClassifyTypeGuards(t *testing.T) {
	use := `"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"bash s/research-sdd-status.sh /t --next"}}]`
	if _, ok := Classify([]byte(`{"type":"assistant","message":{`+use+`}}`), Options{}); !ok {
		t.Error("an assistant tool_use is evidence")
	}
	for _, typ := range []string{"user", "system", ""} {
		if ev, ok := Classify([]byte(`{"type":"`+typ+`","message":{`+use+`}}`), Options{}); ok {
			t.Errorf("a %q entry is not a tool call of the session: %+v", typ, ev)
		}
	}
	slash := `"content":"<command-name>/research-sdd</command-name>"`
	if _, ok := Classify([]byte(`{"type":"user","message":{`+slash+`}}`), Options{}); !ok {
		t.Error("a user slash command is evidence")
	}
	for _, typ := range []string{"assistant", "system", ""} {
		if ev, ok := Classify([]byte(`{"type":"`+typ+`","message":{`+slash+`}}`), Options{}); ok {
			t.Errorf("a %q entry quoting the tag is not the user's command: %+v", typ, ev)
		}
	}
}
