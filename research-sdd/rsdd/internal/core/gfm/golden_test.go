package gfm

import (
	"flag"
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
	d := Parse(mustRead(t, "testdata/fixtures/state/RESEARCH-STATE.md"))
	if d.State != StateTables || len(d.Tables) != 3 {
		t.Fatalf("state fixture: want 3 tables (backlog, 5-column deferred, iteration history), got %d", len(d.Tables))
	}
	if h := d.Tables[0].Header.Text(); len(h) != 4 {
		t.Errorf("backlog header = %q", h)
	}
	if got := len(d.Tables[0].Rows); got != 12 {
		t.Errorf("backlog data rows = %d want 12", got)
	}
	for i, r := range d.Tables[0].Rows {
		if r.Len() != 4 {
			t.Errorf("backlog row %d has %d cells, want 4 (an escaped pipe must not add a column): %q", i, r.Len(), r.Source)
		}
	}
	for i, r := range d.Tables[1].Rows {
		if r.Len() != 5 {
			t.Errorf("deferred row %d has %d cells, want 5: %q", i, r.Len(), r.Source)
		}
	}
	if got := len(d.Tables[2].Rows); got != 9 {
		t.Errorf("iteration rows = %d want 9", got)
	}
	for i, r := range d.Tables[2].Rows {
		if r.Len() != 4 {
			t.Errorf("iteration row %d has %d cells, want 4: %q", i, r.Len(), r.Source)
		}
	}
}
