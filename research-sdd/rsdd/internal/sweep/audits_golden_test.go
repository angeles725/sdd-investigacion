package sweep

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// testdata/audits/golden/cases.txt is the recorded behaviour of the frozen scripts: for every scenario of
// audits_scenarios_test.go marked golden, the world it builds (plain files and directories, each file with its age)
// and what sweep-audits.sh, sweep-audits-hook.sh and sweep-audits-hook.sh --full printed there. This file replays
// the golden against the Go command without bash, so it also runs under -tags nodiff; audits_golden_diff_test.go
// (!nodiff) records it and checks it against the live frozen scripts, which is what keeps it honest.
//
// The file is regenerated whole by `go test -run TestUpdateAuditsGolden -update-audits` (every golden scenario,
// whatever -run says), never by hand. Frame format, counts in bytes, every chunk followed by "\n":
//
//	@@case <name>
//	@@dir <relative path> 0                          a directory (the empty ones matter)
//	@@file <relative path> <age in seconds> <n>      a file, dated <age> before the start of the run
//	@@env <KEY> <n>                                  an environment variable of the run
//	@@rc <n> / @@out <n> / @@err <n> / @@hook <n> / @@hookfull <n>
//	@@end
//
// Paths are relative to the sandbox; {root} stands for the sandbox in file contents, env values and outputs.

type auditGoldFile struct {
	rel  string
	age  int64
	data []byte
}

type auditGold struct {
	name                     string
	dirs                     []string
	files                    []auditGoldFile
	env                      [][2]string
	rc                       int
	out, err, hook, hookFull string
}

func parseAuditGold(t testing.TB, b []byte) []auditGold {
	t.Helper()
	var cases []auditGold
	line := func() string {
		i := bytes.IndexByte(b, '\n')
		if i < 0 {
			t.Fatalf("audits golden: truncated frame")
		}
		l := string(b[:i])
		b = b[i+1:]
		return l
	}
	for len(b) > 0 {
		h := line()
		name, ok := strings.CutPrefix(h, "@@case ")
		if !ok {
			t.Fatalf("audits golden: expected @@case, got %q", h)
		}
		c := auditGold{name: name}
		for {
			h = line()
			if h == "@@end" {
				break
			}
			kind, rest, _ := strings.Cut(strings.TrimPrefix(h, "@@"), " ")
			args := strings.Fields(rest)
			if len(args) == 0 {
				t.Fatalf("audits golden: bad frame header %q", h)
			}
			n, err := strconv.Atoi(args[len(args)-1])
			if err != nil || n < 0 || len(b) < n+1 || b[n] != '\n' {
				t.Fatalf("audits golden: frame %q is not newline-terminated", h)
			}
			chunk := string(b[:n])
			b = b[n+1:]
			args = args[:len(args)-1]
			switch kind {
			case "dir":
				c.dirs = append(c.dirs, args[0])
			case "file":
				age, _ := strconv.ParseInt(args[1], 10, 64)
				c.files = append(c.files, auditGoldFile{rel: args[0], age: age, data: []byte(chunk)})
			case "env":
				c.env = append(c.env, [2]string{args[0], chunk})
			case "rc":
				c.rc, _ = strconv.Atoi(chunk)
			case "out":
				c.out = chunk
			case "err":
				c.err = chunk
			case "hook":
				c.hook = chunk
			case "hookfull":
				c.hookFull = chunk
			default:
				t.Fatalf("audits golden: unknown frame %q", h)
			}
		}
		cases = append(cases, c)
	}
	return cases
}

func formatAuditGold(cases []auditGold) []byte {
	var b bytes.Buffer
	chunk := func(head, data string) { fmt.Fprintf(&b, "@@%s %d\n%s\n", head, len(data), data) }
	for _, c := range cases {
		fmt.Fprintf(&b, "@@case %s\n", c.name)
		for _, d := range c.dirs {
			chunk("dir "+d, "")
		}
		for _, f := range c.files {
			chunk(fmt.Sprintf("file %s %d", f.rel, f.age), string(f.data))
		}
		for _, e := range c.env {
			chunk("env "+e[0], e[1])
		}
		chunk("rc", strconv.Itoa(c.rc))
		chunk("out", c.out)
		chunk("err", c.err)
		chunk("hook", c.hook)
		chunk("hookfull", c.hookFull)
		b.WriteString("@@end\n")
	}
	return b.Bytes()
}

// build lays the case's world out under the sandbox of w.
func (c auditGold) build(w *world) {
	w.t.Helper()
	for _, d := range c.dirs {
		w.must(os.MkdirAll(filepath.Join(w.root, d), 0o755))
	}
	for _, f := range c.files {
		p := filepath.Join(w.root, f.rel)
		w.must(os.MkdirAll(filepath.Dir(p), 0o755))
		w.must(os.WriteFile(p, bytes.ReplaceAll(f.data, []byte("{root}"), []byte(w.root)), 0o644))
		mt := w.now.Add(-time.Duration(f.age) * time.Second)
		w.must(os.Chtimes(p, mt, mt))
	}
	for _, e := range c.env {
		w.env[e[0]] = strings.ReplaceAll(e[1], "{root}", w.root)
	}
}

func (c auditGold) want(w *world, s string) string { return strings.ReplaceAll(s, "{root}", w.root) }

const auditGoldPath = "testdata/audits/golden/cases.txt"

func readAuditGold(t testing.TB) []auditGold {
	t.Helper()
	b, err := os.ReadFile(auditGoldPath)
	if err != nil {
		t.Fatal(err)
	}
	return parseAuditGold(t, b)
}

func goldenAuditScenarios() []auditScenario {
	var out []auditScenario
	for _, sc := range auditScenarios() {
		if sc.golden {
			out = append(out, sc)
		}
	}
	return out
}

func TestAuditsGoldenReplay(t *testing.T) {
	for _, c := range readAuditGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			r := w.runAudits()
			if r.rc != c.rc || r.out != c.want(w, c.out) || r.err != c.want(w, c.err) {
				t.Errorf("report: rc=%d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s", r.rc, c.rc, r.out, c.want(w, c.out), r.err, c.want(w, c.err))
			}
			for _, h := range []struct {
				what, want string
				args       []string
			}{{"hook", c.hook, nil}, {"hook --full", c.hookFull, []string{"--full"}}} {
				r := w.runAuditsHook(h.args...)
				if r.rc != 0 || r.err != "" || r.out != c.want(w, h.want) {
					t.Errorf("%s: rc=%d stderr=%q\ngot:\n%s\nwant:\n%s", h.what, r.rc, r.err, r.out, c.want(w, h.want))
				}
			}
		})
	}
}

// A golden that lost a case, or kept one whose scenario is gone, must fail: an update that was filtered or
// aborted half-way would otherwise replay a shorter corpus and pass.
func TestAuditsGoldenIsComplete(t *testing.T) {
	cases := readAuditGold(t)
	want := goldenAuditScenarios()
	if len(cases) != len(want) {
		t.Fatalf("golden holds %d cases, the scenario table marks %d golden: regenerate with -update-audits", len(cases), len(want))
	}
	for i, c := range cases {
		if c.name != want[i].name {
			t.Errorf("golden case %d is %q, the table has %q", i, c.name, want[i].name)
		}
	}
	if len(cases) < 30 {
		t.Errorf("the golden holds %d cases; a truncated golden must fail, not pass", len(cases))
	}
}

// The corpus is meaningful: it holds each line the sweep can print, so a golden recorded from a broken script
// cannot silently drop one.
func TestAuditsGoldenCoverage(t *testing.T) {
	var all strings.Builder
	for _, c := range readAuditGold(t) {
		all.WriteString(c.out + c.err)
	}
	for _, want := range []string{"PENDING  ", "status: none", "status: wip", "~3 audited claims", "ESCALATED (aged ", "age: 0d\n",
		"INFO: corpus not found (absent-input): ", "INFO: corpus exists, no audits found (empty-input): ", "target(s) not traversed (absent-input)",
		"WARN: ", "PARTIAL: ", "Nothing to review.", "For each PENDING audit", "Summary: 0 pending / 0 audits",
		"sweep-audits: cannot find ", "sweep-audits: ERROR — no usable target paths in "} {
		if !strings.Contains(all.String(), want) {
			t.Errorf("no golden case prints %q", want)
		}
	}
}

func TestAuditGoldFormatRoundTrip(t *testing.T) {
	in := []auditGold{
		{name: "one", dirs: []string{"a/empty"}, files: []auditGoldFile{{rel: "a/x.md", age: 90, data: []byte("line\n\n@@end\n")}},
			env: [][2]string{{"K", "v {root}"}}, rc: 1, out: "o\n", err: "e", hook: "h", hookFull: ""},
		{name: "two", rc: 0},
	}
	got := parseAuditGold(t, formatAuditGold(in))
	if len(got) != 2 || got[0].name != "one" || got[1].name != "two" {
		t.Fatalf("round trip lost a case: %+v", got)
	}
	c := got[0]
	if len(c.dirs) != 1 || c.dirs[0] != "a/empty" || len(c.files) != 1 || c.files[0].age != 90 || string(c.files[0].data) != "line\n\n@@end\n" ||
		len(c.env) != 1 || c.env[0] != [2]string{"K", "v {root}"} || c.rc != 1 || c.out != "o\n" || c.err != "e" || c.hook != "h" || c.hookFull != "" {
		t.Errorf("round trip changed the case: %+v", c)
	}
}
