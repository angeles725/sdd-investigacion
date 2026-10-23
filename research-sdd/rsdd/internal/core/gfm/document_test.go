package gfm

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseStates(t *testing.T) {
	// absent-input / empty-input / no-match are three distinct signals (kit CLAUDE.md section 7).
	if d := Parse(""); d.State != StateEmptyInput || len(d.Tables) != 0 || d.Lines != 0 {
		t.Errorf("empty source: %+v", d)
	}
	if d := Parse("just prose\nmore prose with a | pipe\n"); d.State != StateNoTables || len(d.Tables) != 0 || d.Lines != 2 {
		t.Errorf("prose only: %+v", d)
	}
	if d := Parse("\n"); d.State != StateNoTables || d.Lines != 1 {
		t.Errorf("single blank line: %+v", d)
	}
	if d := Parse("| a |\n|---|\n| 1 |\n"); d.State != StateTables || len(d.Tables) != 1 {
		t.Errorf("table: %+v", d)
	}
}

func TestReadFileAbsent(t *testing.T) {
	_, err := ReadFile(filepath.Join(t.TempDir(), "missing.md"))
	if !errors.Is(err, ErrAbsentInput) {
		t.Fatalf("absent file err = %v, want ErrAbsentInput", err)
	}
	p := filepath.Join(t.TempDir(), "empty.md")
	if werr := os.WriteFile(p, nil, 0o600); werr != nil {
		t.Fatal(werr)
	}
	d, err := ReadFile(p)
	if err != nil || d.State != StateEmptyInput {
		t.Fatalf("empty file: state=%v err=%v", d.State, err)
	}
	// a directory is neither absent nor a document: a typed read error, never an empty document
	_, err = ReadFile(t.TempDir())
	if err == nil || errors.Is(err, ErrAbsentInput) {
		t.Fatalf("directory err = %v, want a non-absent error", err)
	}
}

func TestParseTableStructure(t *testing.T) {
	src := "# Title\n\nprose | not a row\n\n| H1 | H2 |\n|:--|--:|\n| a | b |\n| c\\| | d |\n\nmore prose\n\n| X |\n|---|\n| y |"
	d := Parse(src) // last row has NO trailing newline
	if d.State != StateTables || len(d.Tables) != 2 {
		t.Fatalf("doc = %+v", d)
	}
	t1 := d.Tables[0]
	if t1.Header == nil || t1.Separator == nil {
		t.Fatalf("table 1 lost header/separator: %+v", t1)
	}
	if t1.Header.Line != 5 || t1.Separator.Line != 6 || !t1.Separator.Sep || t1.Header.Sep {
		t.Errorf("table 1 header/separator lines = %d/%d sep=%v/%v", t1.Header.Line, t1.Separator.Line, t1.Header.Sep, t1.Separator.Sep)
	}
	if !reflect.DeepEqual(t1.Header.Text(), []string{"H1", "H2"}) {
		t.Errorf("header = %q", t1.Header.Text())
	}
	if len(t1.Rows) != 2 || t1.Rows[0].Line != 7 || t1.Rows[1].Line != 8 {
		t.Fatalf("rows = %+v", t1.Rows)
	}
	if got := t1.Rows[1].Text(); !reflect.DeepEqual(got, []string{"c|", "d"}) {
		t.Errorf("escaped cell = %q", got)
	}
	t2 := d.Tables[1]
	if t2.Header.Line != 12 || len(t2.Rows) != 1 || t2.Rows[0].Line != 14 || !reflect.DeepEqual(t2.Rows[0].Text(), []string{"y"}) {
		t.Errorf("table 2 (last row without trailing newline) = %+v rows=%+v", t2, t2.Rows)
	}
}

func TestParseTrailingNewlineIrrelevant(t *testing.T) {
	// The kit once never validated the last field of every row because of a missing trailing newline.
	body := "| a | b |\n|---|---|\n| 1 | 2\\| |\n| last\\| | z"
	with, without := Parse(body+"\n"), Parse(body)
	if with.Lines != without.Lines || !reflect.DeepEqual(with.Tables, without.Tables) {
		t.Fatalf("trailing newline changed the parse:\nwith:    %+v\nwithout: %+v", with, without)
	}
	if len(without.Tables) != 1 {
		t.Fatalf("want 1 table, got %d", len(without.Tables))
	}
	rows := without.Tables[0].Rows
	if len(rows) != 2 || !reflect.DeepEqual(rows[1].Text(), []string{"last|", "z"}) {
		t.Fatalf("last row = %+v", rows)
	}
}

func TestParseRowsWithoutSeparator(t *testing.T) {
	// A block of pipe rows with no separator on line 2 has no header: every row is a data row.
	d := Parse("| a | b |\n| c | d |\n")
	if len(d.Tables) != 1 {
		t.Fatalf("want 1 table, got %d", len(d.Tables))
	}
	if d.Tables[0].Header != nil || d.Tables[0].Separator != nil || len(d.Tables[0].Rows) != 2 {
		t.Fatalf("headerless block = %+v", d.Tables)
	}
}

func TestParseSecondSeparatorStaysDistinct(t *testing.T) {
	d := Parse("| a |\n|---|\n| x |\n|---|\n| y |\n")
	if len(d.Tables) != 1 {
		t.Fatalf("want 1 table, got %d", len(d.Tables))
	}
	rows := d.Tables[0].Rows
	if len(rows) != 3 || rows[0].Sep || !rows[1].Sep || rows[2].Sep {
		t.Fatalf("rows = %+v", rows)
	}
}

func TestRowsIteratorEarlyStopAndLines(t *testing.T) {
	src := "intro\n| a | b |\n|---|---|\ntext\n| c | d |\n"
	var lines []int
	for r := range Rows(src, Options{}) {
		lines = append(lines, r.Line)
	}
	if !reflect.DeepEqual(lines, []int{2, 3, 5}) {
		t.Fatalf("lines = %v", lines)
	}
	n := 0
	for range Rows(src, Options{}) {
		n++
		break
	}
	if n != 1 {
		t.Fatalf("early stop yielded %d rows", n)
	}
}

func TestRowsTargetsProseNeverRows(t *testing.T) {
	// TARGETS.md detail prose cites paths and tables in sentences; none of that is a row.
	src := "Detail: see `/v2` and `/vN` in a | b sentence.\n  - item with | pipe\n| Slug | Path |\n|---|---|\n| t | `$RESEARCH_HOME/x` |\n"
	var got [][]string
	for r := range Rows(src, Options{}) {
		got = append(got, r.Text())
	}
	want := [][]string{{"Slug", "Path"}, {"---", "---"}, {"t", "`$RESEARCH_HOME/x`"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rows = %q want %q", got, want)
	}
}
