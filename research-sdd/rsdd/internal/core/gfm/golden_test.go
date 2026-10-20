package gfm

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "rewrite testdata/golden/*.golden from the current output (review the diff by hand)")

// dumpRows renders every row as `L<line> [SEP] ⟨cell⟩⟨cell⟩…` using the unescaped Text view.
func dumpRows(src string) string {
	var b strings.Builder
	for r := range Rows(src, Options{}) {
		b.WriteString("L")
		b.WriteString(strconv.Itoa(r.Line))
		if r.Sep {
			b.WriteString(" SEP")
		}
		b.WriteString(" ")
		for _, c := range r.Text() {
			b.WriteString("⟨" + c + "⟩")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func TestGoldenFixtures(t *testing.T) {
	var inputs []string
	for _, root := range []string{"testdata/fixtures", "testdata/edge"} {
		err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() && strings.HasSuffix(p, ".md") {
				inputs = append(inputs, p)
			}
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(inputs) < 8 {
		t.Fatalf("only %d golden inputs found; the fixture tree moved", len(inputs))
	}
	for _, in := range inputs {
		name := strings.ReplaceAll(strings.TrimPrefix(in, "testdata/"), "/", "_")
		golden := filepath.Join("testdata", "golden", name+".golden")
		got := dumpRows(mustRead(t, in))
		if *update {
			if err := os.MkdirAll(filepath.Dir(golden), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(golden, []byte(got), 0o600); err != nil {
				t.Fatal(err)
			}
			continue
		}
		want, err := os.ReadFile(golden)
		if err != nil {
			t.Errorf("%s: golden missing (%v); run with -update and review", in, err)
			continue
		}
		if string(want) != got {
			t.Errorf("%s differs from %s\n--- want\n%s--- got\n%s", in, golden, want, got)
		}
	}
}

// TestParityFixtureShape checks the structure of the shared parity fixture (the one table-reader-parity.test.sh
// feeds to every bash reader): three tables, namely the 4-column backlog (12 data rows), the 5-column deferred
// table (4 rows) and the 4-column iteration history (9 rows). The expected counts come from reading the fixture
// under the GFM rule, where an escaped pipe never adds a column; they were not copied from this package's output.
// A cell count other than the table width means an escaped pipe was treated as a separator.
func TestParityFixtureShape(t *testing.T) {
	for _, p := range parityShapeProblems(mustRead(t, "testdata/fixtures/state/RESEARCH-STATE.md")) {
		t.Error(p)
	}
}

// parityShape is the expected structure of the parity fixture, in document order.
var parityShape = []struct {
	name       string
	cols, rows int
}{
	{"backlog", 4, 12},
	{"deferred", 5, 4},
	{"iteration history", 4, 9},
}

// parityShapeProblems lists every deviation from parityShape: the table count, and for each table its header
// width, its data-row count and every row's width. A missing table is reported by the count and never skipped.
func parityShapeProblems(src string) []string {
	d := Parse(src)
	if d.State != StateTables || len(d.Tables) != len(parityShape) {
		return []string{fmt.Sprintf("want %d tables, got %d (state %v)", len(parityShape), len(d.Tables), d.State)}
	}
	var out []string
	for i, want := range parityShape {
		tb := d.Tables[i]
		if tb.Header == nil || tb.Separator == nil {
			out = append(out, want.name+": no header/separator")
			continue
		}
		if got := tb.Header.Len(); got != want.cols {
			out = append(out, fmt.Sprintf("%s: header has %d cells, want %d", want.name, got, want.cols))
		}
		if got := len(tb.Rows); got != want.rows {
			out = append(out, fmt.Sprintf("%s: %d data rows, want %d", want.name, got, want.rows))
		}
		for j, r := range tb.Rows {
			if r.Len() != want.cols {
				out = append(out, fmt.Sprintf("%s: row %d has %d cells, want %d (an escaped pipe must not add a column): %q", want.name, j, r.Len(), want.cols, r.Source))
			}
		}
	}
	return out
}

// The shape check must bite: a missing table or a changed row count has to be reported.
func TestParityShapeBites(t *testing.T) {
	src := mustRead(t, "testdata/fixtures/state/RESEARCH-STATE.md")
	for name, mut := range map[string]string{
		"deferred table removed": strings.Replace(src, "| Priority | ID | Gap | Artifact | Status |", "no table here", 1),
		"deferred row dropped":   strings.Replace(src, "| deferred | B3-G9 | g\\\\\\|triple | x | parked |\n", "", 1),
		"iteration row dropped":  strings.Replace(src, "| 9 | f | B9 | 1 \\\\\\| a |\n", "", 1),
		"backlog row dropped":    strings.Replace(src, "| high | B1-G1 mid\\|esc | x | pending |\n", "", 1),
	} {
		if mut == src {
			t.Fatalf("%s: the mutation did not apply; the fixture text moved", name)
		}
		if len(parityShapeProblems(mut)) == 0 {
			t.Errorf("%s: the shape check still passes", name)
		}
	}
}
