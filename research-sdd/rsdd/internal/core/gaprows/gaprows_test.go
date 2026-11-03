package gaprows

import (
	"reflect"
	"strings"
	"testing"
)

const tbl = "| Priority | Gap | Type | Status |\n|---|---|---|---|\n"

func rowsOf(t *testing.T, src string) []Record {
	t.Helper()
	return Parse(src).Records
}

func TestParseRowForms(t *testing.T) {
	for _, c := range []struct {
		name string
		src  string
		want []Record
	}{
		{"single row", "| high | B1-G2 how it works | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B1-G2", Block: "1", Pending: true, Text: "how it works"}}},
		{"first, middle and last of three", tbl + "| high | B1-G1 first | w | pending |\n| low | B2-G1 middle | w | done |\n| medium | B3-G1 last | w | Pending review |",
			[]Record{
				{Kind: KindRow, Line: 3, ID: "B1-G1", Block: "1", Pending: true, Text: "first"},
				{Kind: KindRow, Line: 4, ID: "B2-G1", Block: "2", Text: "middle"},
				{Kind: KindRow, Line: 5, ID: "B3-G1", Block: "3", Pending: true, Text: "last"}}},
		{"escaped pipe is one literal pipe", "| high | B4-G1 a \\| b | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B4-G1", Block: "4", Pending: true, Text: "a | b"}}},
		{"CRLF line endings", "| high | B5-G1 text | w | pending |\r\n| low | B5-G2 more | w | done |\r\n",
			[]Record{
				{Kind: KindRow, Line: 1, ID: "B5-G1", Block: "5", Pending: true, Text: "text"},
				{Kind: KindRow, Line: 2, ID: "B5-G2", Block: "5", Text: "more"}}},
		{"id alone has empty text", "| high | B6-G1 | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B6-G1", Block: "6", Pending: true}}},
		{"tab inside the text reads as a space", "| high | B7-G1 a\tb | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B7-G1", Block: "7", Pending: true, Text: "a b"}}},
		{"leading zeros are kept in the block", "| high | B01-G1 x | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B01-G1", Block: "01", Pending: true, Text: "x"}}},
		{"indented table row", "  | deferred | B8-G1 x | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B8-G1", Block: "8", Pending: true, Text: "x"}}},
		{"PENDING folds ASCII case", "| high | B9-G1 x | w | PENDING |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B9-G1", Block: "9", Pending: true, Text: "x"}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := rowsOf(t, c.src); !reflect.DeepEqual(got, c.want) {
				t.Errorf("got  %+v\nwant %+v", got, c.want)
			}
		})
	}
}

func TestParseSkippedAndUnparsed(t *testing.T) {
	long := "| high | B2-G1 " + strings.Repeat("x", 100)
	for _, c := range []struct {
		name string
		src  string
		want []Record
	}{
		{"em-dash priority, not pending: skipped", "| — | B1-G1 closed | w | done |\n", []Record{{Kind: KindSkipped, Line: 1, Cell: "B1-G1 closed"}}},
		{"strike priority, not pending: skipped", "| ~~high~~ | B1-G2 closed | w | done |\n", []Record{{Kind: KindSkipped, Line: 1, Cell: "B1-G2 closed"}}},
		{"numeric priority, not pending: skipped", "| 3 | B1-G3 history | w | done |\n", []Record{{Kind: KindSkipped, Line: 1, Cell: "B1-G3 history"}}},
		{"numeric priority but pending is still a row", "| 3 | B1-G4 x | w | pending |\n",
			[]Record{{Kind: KindRow, Line: 1, ID: "B1-G4", Block: "1", Pending: true, Text: "x"}}},
		{"pending with an em-dash priority and too few cells is unparsed", "| — | B1-G5 x | pending |\n", []Record{{Kind: KindUnparsed, Line: 1, Source: "| — | B1-G5 x | pending |"}}},
		{"unknown priority is unparsed", "| urgent | B1-G6 x | w | pending |\n", []Record{{Kind: KindUnparsed, Line: 1, Source: "| urgent | B1-G6 x | w | pending |"}}},
		{"fewer than four cells is unparsed", "| high | B1-G7 x |\n", []Record{{Kind: KindUnparsed, Line: 1, Source: "| high | B1-G7 x |"}}},
		{"an unparsed line keeps 90 bytes", long + " | pending |\n", []Record{{Kind: KindUnparsed, Line: 1, Source: (long + " | pending |")[:90]}}},
		{"an unparsed CRLF line loses its CR", "| high | B1-G8 x |\r\n", []Record{{Kind: KindUnparsed, Line: 1, Source: "| high | B1-G8 x |"}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			if c.name == "an unparsed line keeps 90 bytes" && len(c.want[0].Source) != 90 {
				t.Fatalf("fixture error: %d bytes", len(c.want[0].Source))
			}
			if got := rowsOf(t, c.src); !reflect.DeepEqual(got, c.want) {
				t.Errorf("got  %+v\nwant %+v", got, c.want)
			}
		})
	}
}

func TestParseTypedStates(t *testing.T) {
	if got := Parse(""); !got.Empty || len(got.Records) != 0 {
		t.Errorf("empty input: %+v, want Empty and no records", got)
	}
	got := Parse("# title\n\nno table here\n")
	if got.Empty || len(got.Records) != 0 || got.Rows() != 0 {
		t.Errorf("text without gap rows: %+v, want not Empty and no records (no-match)", got)
	}
	for _, src := range []string{"| high | plain text | w | pending |\n", "| high | B1 no gap | w | pending |\n", "| high | b1-g1 lower | w | pending |\n",
		"| high | B1-G1x glued | w | pending |\n", "not a table | B1-G1 x |\n", "|---|---|---|---|\n", "|\n", "||\n"} {
		if got := Parse(src); len(got.Records) != 0 {
			t.Errorf("%q: %+v, want no record", src, got.Records)
		}
	}
	mixed := Parse("| high | B1-G1 a | w | pending |\n| — | B1-G2 b | w | done |\n| high | B1-G3 c |\n")
	if mixed.Rows() != 1 || mixed.Skipped() != 1 || mixed.Unparsed() != 1 {
		t.Errorf("counts rows=%d skipped=%d unparsed=%d, want 1/1/1", mixed.Rows(), mixed.Skipped(), mixed.Unparsed())
	}
}

// A literal 0x01 byte is ordinary text here; the awk placeholder turned it into a pipe (documented divergence D1).
func TestParseKeepsLiteralControlByte(t *testing.T) {
	got := rowsOf(t, "| high | B1-G1 a\x01b | w | pending |\n")
	if len(got) != 1 || got[0].Text != "a\x01b" {
		t.Errorf("got %+v, want the 0x01 byte kept", got)
	}
}

func TestBulletForms(t *testing.T) {
	for _, c := range []struct {
		name, src, id, want string
		found               bool
	}{
		{"plain", "- **B1-G2** the text\n", "B1-G2", "- **B1-G2** the text", true},
		{"asterisk bullet", "* **B1-G2** the text\n", "B1-G2", "* **B1-G2** the text", true},
		{"bracketed id", "- **[B1-G2]** the text\n", "B1-G2", "- **[B1-G2]** the text", true},
		{"parenthetical note", "- **B1-G2 (open, note)** the text\n", "B1-G2", "- **B1-G2 (open, note)** the text", true},
		{"colon form", "- **B1-G2**: the text\n", "B1-G2", "- **B1-G2**: the text", true},
		{"indented bullet", "   - **B1-G2** the text\n", "B1-G2", "   - **B1-G2** the text", true},
		{"B4-G1 never matches B4-G10", "- **B4-G10** other\n", "B4-G1", "", false},
		{"B4-G10 matches only itself", "- **B4-G1** a\n- **B4-G10** b\n", "B4-G10", "- **B4-G10** b", true},
		{"prose mention is not a bullet", "see B1-G2 for the text\n", "B1-G2", "", false},
		{"a bold id without a list marker is not a bullet", "**B1-G2** text\n", "B1-G2", "", false},
		{"continuation lines are joined", "- **B1-G2** first\nsecond\n  third\n\nafter\n", "B1-G2", "- **B1-G2** first second   third", true},
		{"stops at the next bullet", "- **B1-G2** first\nmore\n- **B1-G3** next\n", "B1-G2", "- **B1-G2** first more", true},
		{"stops at a heading", "- **B1-G2** first\n## Next\n", "B1-G2", "- **B1-G2** first", true},
		{"stops at a whitespace-only line", "- **B1-G2** first\n \t \nmore\n", "B1-G2", "- **B1-G2** first", true},
		{"at most seven continuation lines", "- **B1-G2** l0\n1\n2\n3\n4\n5\n6\n7\n8\n", "B1-G2", "- **B1-G2** l0 1 2 3 4 5 6 7", true},
		{"the first definition wins", "- **B1-G2** one\n\n- **B1-G2** two\n", "B1-G2", "- **B1-G2** one", true},
		{"CRLF", "- **B1-G2** first\r\nmore\r\n", "B1-G2", "- **B1-G2** first more", true},
		{"no trailing newline", "- **B1-G2** last", "B1-G2", "- **B1-G2** last", true},
		{"empty source", "", "B1-G2", "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			got, found := Bullet(c.src, c.id)
			if got != c.want || found != c.found {
				t.Errorf("Bullet = (%q, %v), want (%q, %v)", got, found, c.want, c.found)
			}
		})
	}
}

func TestBulletsIndexIsReusable(t *testing.T) {
	b := ParseBullets("- **B1-G1** a\n- **B1-G2** b\n")
	for i := 0; i < 2; i++ { // asking twice and out of order gives the same answers
		if got, ok := b.Text("B1-G2"); !ok || got != "- **B1-G2** b" {
			t.Errorf("B1-G2 = (%q, %v)", got, ok)
		}
		if got, ok := b.Text("B1-G1"); !ok || got != "- **B1-G1** a" {
			t.Errorf("B1-G1 = (%q, %v)", got, ok)
		}
	}
}

func TestOverlap(t *testing.T) {
	for _, c := range []struct {
		name, row, bullet string
		shared, total     int
	}{
		{"identical", "widgets frobnicate sprockets", "- **B1-G1** widgets frobnicate sprockets", 3, 3},
		{"disjoint", "cats and dogs", "widgets frobnicate", 0, 2},
		{"stop words and short words are ignored", "the of an to it", "the of an to it", 0, 0},
		{"plural stem: months matches month", "months", "month", 1, 1},
		{"a four-byte plural is stemmed", "usds", "usd", 1, 1},
		{"a three-byte word ending in s is not stemmed", "bus", "bu", 0, 1},
		{"ss is kept: class does not match clas", "class", "clas", 0, 1},
		{"only one s is stripped", "bosses", "boss", 0, 1},
		{"case is folded", "Widgets", "widget", 1, 1},
		{"words repeat once", "foo foo foo", "foo", 1, 1},
		{"digit-initial tokens are invisible", "9.5.0 1166", "9.5.0 1166", 0, 0},
		{"dots and underscores belong to the word", "a.b_c", "a.b_c", 1, 1},
		{"a lone letter is not a word", "a b c d", "a b c d", 0, 0},
		{"empty row", "", "anything here", 0, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			if s, n := Overlap(c.row, c.bullet); s != c.shared || n != c.total {
				t.Errorf("Overlap = %d/%d, want %d/%d", s, n, c.shared, c.total)
			}
		})
	}
}

func TestBlock(t *testing.T) {
	for id, want := range map[string]string{"B50-G6": "50", "B1-G1": "1", "B007-G12": "007", "B9-G": "9", "weird": "weird"} {
		if got := Block(id); got != want {
			t.Errorf("Block(%q) = %q, want %q", id, got, want)
		}
	}
}
