package reasons_test

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

// pkgDir returns this package directory (located through the test file, not the working directory).
func pkgDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Dir(file)
}

func mdPath(t *testing.T) string {
	return filepath.Join(pkgDir(t), "..", "..", "..", "..", "toolbelt", "reason-codes.v1.md")
}

// mdRows counts and extracts registry rows with a method independent of the generator: a table row of the
// registry is a line that starts with "| `"; the code is the text up to the first "` | ", the class is the
// next cell. A missing contract file is a hard failure, never a skip.
func mdRows(t *testing.T) (codes, classes []string) {
	t.Helper()
	b, err := os.ReadFile(mdPath(t))
	if err != nil {
		t.Fatalf("contract file unreadable (must exist): %v", err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if !strings.HasPrefix(line, "| `") {
			continue
		}
		rest := line[3:]
		i := strings.Index(rest, "` | ")
		if i < 0 {
			t.Fatalf("unparseable registry row: %q", line)
		}
		after := rest[i+4:]
		j := strings.Index(after, " | ")
		if j < 0 {
			t.Fatalf("registry row without class cell: %q", line)
		}
		codes = append(codes, rest[:i])
		classes = append(classes, after[:j])
	}
	return codes, classes
}

func TestEveryMarkdownRowIsInTheTable(t *testing.T) {
	codes, classes := mdRows(t)
	if len(codes) < 50 {
		t.Fatalf("independent scan found only %d rows; the scan or the file is broken", len(codes))
	}
	if got := len(reasons.All()); got != len(codes) {
		t.Fatalf("table has %d codes, markdown has %d rows", got, len(codes))
	}
	for i, text := range codes {
		c, ok := reasons.Lookup(text)
		if !ok {
			t.Errorf("row %d (%q) missing from the table", i, text)
			continue
		}
		if string(c.Class()) != classes[i] {
			t.Errorf("row %d class = %q, want %q", i, c.Class(), classes[i])
		}
		if reasons.All()[i] != c {
			t.Errorf("row %d is out of registry order", i)
		}
		if c.Continuation() == "" || c.Meaning() == "" || len(c.Emitters()) == 0 {
			t.Errorf("row %d (%q) lost a column", i, text)
		}
	}
	first, last := reasons.All()[0], reasons.All()[len(codes)-1]
	if first.Text() != codes[0] || last.Text() != codes[len(codes)-1] {
		t.Errorf("first/last row mismatch: %q / %q", first.Text(), last.Text())
	}
}

func TestInputClassRowsAreThePrescribedFour(t *testing.T) {
	var got []string
	for _, c := range reasons.All() {
		if c.Class() == reasons.ClassInput {
			got = append(got, c.Text())
		}
	}
	want := []string{"absent-input", "empty-input", "unclassifiable", "no-match"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("input rows = %v, want %v", got, want)
	}
}

func TestGeneratedTableIsUpToDate(t *testing.T) {
	dir := pkgDir(t)
	committed, err := os.ReadFile(filepath.Join(dir, "table_gen.go"))
	if err != nil {
		t.Fatalf("committed table_gen.go unreadable: %v", err)
	}
	out := filepath.Join(t.TempDir(), "table_gen.go")
	cmd := exec.Command("go", "run", "./gen", "-md", mdPath(t), "-out", out)
	cmd.Dir = dir
	if msg, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generator failed: %v\n%s", err, msg)
	}
	regen, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(regen, committed) {
		t.Fatal("table_gen.go is stale: run go generate ./internal/core/reasons/...")
	}
}

func lookup(t *testing.T, text string) reasons.Code {
	t.Helper()
	c, ok := reasons.Lookup(text)
	if !ok {
		t.Fatalf("registry lacks %q", text)
	}
	return c
}

func TestRender(t *testing.T) {
	cases := []struct {
		code string
		args []string
		want string
	}{
		{"degraded: jq not found on PATH", nil, "degraded: jq not found on PATH"},
		{"degraded: remote-visibility: <v> url empty or unreadable", []string{"origin"}, "degraded: remote-visibility: origin url empty or unreadable"},
		{"degraded: gh issue list (closed) failed for <v> (exit <v>)", []string{"retro.md", "4"}, "degraded: gh issue list (closed) failed for retro.md (exit 4)"},
		{"degraded: ref <v> is not known locally in <v> (no fetch is performed)", []string{"<v>", "x"}, "degraded: ref <v> is not known locally in x (no fetch is performed)"},
	}
	for _, c := range cases {
		got, err := reasons.Render(lookup(t, c.code), c.args...)
		if err != nil || got != c.want {
			t.Errorf("Render(%q, %v) = %q, %v; want %q", c.code, c.args, got, err, c.want)
		}
	}
}

func TestRenderRejectsWrongArgCountAndBadInput(t *testing.T) {
	two := lookup(t, "degraded: gh issue list (closed) failed for <v> (exit <v>)")
	none := lookup(t, "degraded: jq not found on PATH")
	if two.Placeholders() != 2 || none.Placeholders() != 0 {
		t.Fatalf("Placeholders() = %d, %d", two.Placeholders(), none.Placeholders())
	}
	bad := []struct {
		name string
		c    reasons.Code
		args []string
	}{
		{"too few", two, []string{"a"}},
		{"too many", two, []string{"a", "b", "c"}},
		{"none given", two, nil},
		{"extra for none", none, []string{"a"}},
		{"newline in arg", two, []string{"a\nb", "1"}},
		{"zero code", reasons.Code{}, nil},
		{"input class code", lookup(t, "absent-input"), nil},
	}
	for _, c := range bad {
		var buf bytes.Buffer
		if s, err := reasons.Render(c.c, c.args...); err == nil {
			t.Errorf("%s: Render = %q, nil; want an error", c.name, s)
		}
		if err := reasons.Emit(&buf, c.c, c.args...); err == nil || buf.Len() != 0 {
			t.Errorf("%s: Emit err=%v wrote %q; want an error and no output", c.name, err, buf.String())
		}
	}
}

func TestEmitWritesOneNewlineTerminatedLine(t *testing.T) {
	var buf bytes.Buffer
	if err := reasons.Emit(&buf, lookup(t, "degraded: jq not found on PATH")); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "degraded: jq not found on PATH\n" {
		t.Fatalf("got %q", buf.String())
	}
	buf.Reset()
	if err := reasons.EmitDetail(&buf, lookup(t, "degraded: retro not readable:"), "/x/r.md"); err != nil {
		t.Fatal(err)
	}
	if buf.String() != "degraded: retro not readable: /x/r.md\n" {
		t.Fatalf("got %q", buf.String())
	}
	for _, d := range []string{"", "a\nb"} {
		buf.Reset()
		if err := reasons.EmitDetail(&buf, lookup(t, "degraded: retro not readable:"), d); err == nil || buf.Len() != 0 {
			t.Errorf("EmitDetail(%q) err=%v out=%q; want error and no output", d, err, buf.String())
		}
	}
}

func TestEveryDegradedCodeRendersWithItsPlaceholders(t *testing.T) {
	n := 0
	for _, c := range reasons.All() {
		if c.Class() != reasons.ClassDegraded {
			continue
		}
		n++
		args := make([]string, c.Placeholders())
		for i := range args {
			args[i] = "X"
		}
		line, err := reasons.Render(c, args...)
		if err != nil {
			t.Errorf("%q: %v", c.Text(), err)
			continue
		}
		if !strings.HasPrefix(line, "degraded: ") || strings.Contains(line, "<v>") {
			t.Errorf("bad line %q for %q", line, c.Text())
		}
	}
	if n < 40 {
		t.Fatalf("only %d degraded codes rendered", n)
	}
}

func TestZeroCodeIsInvalid(t *testing.T) {
	var z reasons.Code
	if z.Text() != "" || z.Class() != "" || z.Placeholders() != 0 {
		t.Error("zero Code must expose nothing")
	}
}
