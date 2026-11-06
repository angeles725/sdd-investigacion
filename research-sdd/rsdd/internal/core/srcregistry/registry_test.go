package srcregistry

import (
	"strings"
	"testing"
)

const table = "# Preserved\n\n| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks |\n|---|---|---|---|---|---|\n| datasheets/a.pdf | datasheet | https://x/a.pdf | 2026-06-28T00:00:00Z | abc123 | [K] |\n"

func TestParseRowsCells(t *testing.T) {
	rows := ParseRows([]byte(table))
	if len(rows) != 3 {
		t.Fatalf("want header, separator and one row, got %+v", rows)
	}
	if !rows[0].IsHeader() || rows[0].IsSeparator() || rows[1].IsHeader() || !rows[1].IsSeparator() || rows[2].IsHeader() || rows[2].IsSeparator() {
		t.Errorf("classification wrong: %+v", rows)
	}
	want := Row{Line: 5, File: "datasheets/a.pdf", Type: "datasheet", Origin: "https://x/a.pdf", Date: "2026-06-28T00:00:00Z", SHA: "abc123", Citing: "[K]"}
	if rows[2] != want {
		t.Errorf("got %+v want %+v", rows[2], want)
	}
}

func TestParseRowsIgnoresProseAndTabs(t *testing.T) {
	md := "prose | not a row\n\t| \tf \t| t | o | d | s | c |\n"
	rows := ParseRows([]byte(md))
	if len(rows) != 1 || rows[0].File != "f" || rows[0].Line != 2 {
		t.Errorf("%+v", rows)
	}
}

func TestFormatRowAndSafeCell(t *testing.T) {
	if got := FormatRow("d/a.pdf", "d", "https://x", "2026-01-01T00:00:00Z", "ff"); got != "| d/a.pdf | d | https://x | 2026-01-01T00:00:00Z | ff | |" {
		t.Errorf("row %q", got)
	}
	if got := SafeCell("a|b||c"); got != "a%7Cb%7C%7Cc" {
		t.Errorf("cell %q", got)
	}
}

func TestHasRow(t *testing.T) {
	md := []byte(table)
	for _, c := range []struct {
		file, sha string
		want      bool
	}{{"datasheets/a.pdf", "", true}, {"datasheets/a.pdf", "abc123", true}, {"datasheets/a.pdf", "zzz", false}, {"datasheets/b.pdf", "", false}} {
		if got := HasRow(md, c.file, c.sha); got != c.want {
			t.Errorf("%+v got %v", c, got)
		}
	}
}

func TestInsertRowEndOfFirstTable(t *testing.T) {
	md := table + "\n## Structure\n\n| not | the | table |\n"
	got := string(InsertRow([]byte(md), "| NEW |"))
	i, j := strings.Index(got, "| NEW |"), strings.Index(got, "## Structure")
	if i < 0 || j < 0 || i > j || !strings.Contains(got, "[K] |\n| NEW |\n") {
		t.Errorf("row not contiguous above the prose:\n%s", got)
	}
}

func TestInsertRowToleratesBlankInsideTable(t *testing.T) {
	md := "| a |\n\n| b |\nprose\n| c |\n"
	if got := string(InsertRow([]byte(md), "| N |")); got != "| a |\n\n| b |\n| N |\nprose\n| c |\n" {
		t.Errorf("%q", got)
	}
}

func TestInsertRowAppendsWithoutTableAndAddsNewline(t *testing.T) {
	if got := string(InsertRow([]byte("just prose"), "| N |")); got != "just prose\n| N |\n" {
		t.Errorf("%q", got)
	}
	if got := string(InsertRow(nil, "| N |")); got != "| N |\n" {
		t.Errorf("%q", got)
	}
	if got := string(InsertRow([]byte("| a |"), "| N |")); got != "| a |\n| N |\n" {
		t.Errorf("table without final newline: %q", got)
	}
}

func TestRetargetFileIsShaScoped(t *testing.T) {
	md := "| File | x | x | x | sha256 |\n| d/a.pdf | t | o | d | aaa | |\n| d/a.pdf | t | o | d | bbb | |\n| d/b.pdf | t | o | d | aaa | |\n"
	out, others := RetargetFile([]byte(md), "d/a.pdf", "d/a.aaa.pdf", "aaa")
	want := "| File | x | x | x | sha256 |\n| d/a.aaa.pdf | t | o | d | aaa | |\n| d/a.pdf | t | o | d | bbb | |\n| d/b.pdf | t | o | d | aaa | |\n"
	if string(out) != want || others != 1 {
		t.Errorf("others=%d\n%s", others, out)
	}
}

func TestRetargetFileKeepsLeadingBlankAndCellPadding(t *testing.T) {
	out, _ := RetargetFile([]byte("  |  d/a.pdf  | t | o | d | s | |\n"), "d/a.pdf", "d/n.pdf", "s")
	if string(out) != "  | d/n.pdf | t | o | d | s | |\n" {
		t.Errorf("%q", out)
	}
}
