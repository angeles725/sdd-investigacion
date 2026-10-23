package gfm

import (
	"reflect"
	"strings"
	"testing"
)

// GFM rule (verified against GitHub's renderer, PR #2147): ANY `\|` inside a cell is an escaped pipe, however
// many backslashes precede it. Cell text keeps the extra backslashes: `x\\| y` is the ONE cell `x\| y` here
// (the kit readers unescape exactly one backslash-pipe), and GitHub renders the same row as one cell too.
//
// Edge cases beyond that rule, observed on 2026-10-19 with `gh api -X POST /markdown -f mode=gfm` over a
// synthetic table:
//   - empty cell `| x | |`            -> cell kept, empty
//   - `| y\ | z |`                     -> a backslash at the end of a cell is kept literally (`y\`)
//   - `| z | w` (no trailing pipe)     -> row is read, cells z and w
//   - `u | v |` (no leading pipe)      -> row is read inside a table; the kit's leading-pipe readers do not read it
//   - `| e\\| f | g\\\| h |`           -> two cells (`e| f`, `g\| h` after inline rendering)
//   - tab inside / around a cell       -> kept inside, trimmed at the edges
//   - `| last\|` (escaped last pipe)   -> ONE cell `last|`, padded with an empty cell to the header width
//   - `| p | r || s |` (extra cell)    -> GitHub drops the extra cell; this package keeps every cell (the kit
//     readers count cells to flag malformed rows, so truncation would hide them)

func TestSplitRowText(t *testing.T) {
	lead := Options{}
	any := Options{Shape: ShapeAnyPipe}
	cases := []struct {
		name string
		line string
		opt  Options
		ok   bool
		text []string
		raw  []string
	}{
		{"plain", "| a | b |", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"no spaces", "|a|b|", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		// the three escape runs in the FIRST cell
		{"one backslash first", `| x\| y | z |`, lead, true, []string{"x| y", "z"}, []string{`x\| y`, "z"}},
		{"two backslashes first", `| x\\| y | z |`, lead, true, []string{`x\| y`, "z"}, []string{`x\\| y`, "z"}},
		{"three backslashes first", `| x\\\| y | z |`, lead, true, []string{`x\\| y`, "z"}, []string{`x\\\| y`, "z"}},
		// MIDDLE cell
		{"one backslash middle", `| a | m\| n | b |`, lead, true, []string{"a", "m| n", "b"}, []string{"a", `m\| n`, "b"}},
		{"two backslashes middle", `| a | m\\| n | b |`, lead, true, []string{"a", `m\| n`, "b"}, []string{"a", `m\\| n`, "b"}},
		{"three backslashes middle", `| a | m\\\| n | b |`, lead, true, []string{"a", `m\\| n`, "b"}, []string{"a", `m\\\| n`, "b"}},
		// LAST cell, with and without the closing pipe
		{"one backslash last", `| a | z\| y |`, lead, true, []string{"a", "z| y"}, []string{"a", `z\| y`}},
		{"two backslashes last", `| a | z\\| y |`, lead, true, []string{"a", `z\| y`}, []string{"a", `z\\| y`}},
		{"three backslashes last", `| a | z\\\| y |`, lead, true, []string{"a", `z\\| y`}, []string{"a", `z\\\| y`}},
		{"escaped pipe is the last char, closing pipe present", `| a | b\| |`, lead, true, []string{"a", "b|"}, []string{"a", `b\|`}},
		{"escaped pipe is the last char, no closing pipe", `| a | b\|`, lead, true, []string{"a", "b|"}, []string{"a", `b\|`}},
		{"even run is last char, no closing pipe", `| a | b\\|`, lead, true, []string{"a", `b\|`}, []string{"a", `b\\|`}},
		// SINGLE-cell rows
		{"single cell", "| a |", lead, true, []string{"a"}, []string{"a"}},
		{"single cell no closing pipe", "| a", lead, true, []string{"a"}, []string{"a"}},
		{"single escaped cell", `| a\| |`, lead, true, []string{"a|"}, []string{`a\|`}},
		{"single escaped only", `|\||`, lead, true, []string{"|"}, []string{`\|`}},
		// missing pipes, empties, whitespace
		{"no closing pipe", "| a | b", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"no opening pipe, leading-pipe shape", "a | b |", lead, false, nil, nil},
		{"no opening pipe, any-pipe shape", "a | b |", any, true, []string{"a", "b"}, []string{"a", "b"}},
		{"empty cell middle", "| a | | c |", lead, true, []string{"a", "", "c"}, []string{"a", "", "c"}},
		{"empty cell last", "| a | |", lead, true, []string{"a", ""}, []string{"a", ""}},
		{"only blank cell", "| |", lead, true, []string{""}, []string{""}},
		{"bare pipe is a row with zero cells", "|", lead, true, []string{}, []string{}},
		{"double pipe has zero cells (awk split of empty body)", "||", lead, true, []string{}, []string{}},
		{"extra cell is kept", "| p | r || s |", lead, true, []string{"p", "r", "", "s"}, []string{"p", "r", "", "s"}},
		{"leading blanks", " \t| a | b |", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"trailing blanks", "| a | b |  \t", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"tab padded cells", "|\ta\t|\tb\t|", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"tab inside cell kept", "| a\tb | c |", lead, true, []string{"a\tb", "c"}, []string{"a\tb", "c"}},
		{"backslash at end of cell", `| a\ | b |`, lead, true, []string{`a\`, "b"}, []string{`a\`, "b"}},
		{"backslash at end of line", `| a | b\`, lead, true, []string{"a", `b\`}, []string{"a", `b\`}},
		{"utf8", "| é | ✅ done \\| y |", lead, true, []string{"é", "✅ done | y"}, []string{"é", `✅ done \| y`}},
		// rows rule: prose is never a row
		{"prose", "plain prose", lead, false, nil, nil},
		{"prose any-pipe", "plain prose", any, false, nil, nil},
		{"empty line", "", lead, false, nil, nil},
		{"prose with a pipe is not a leading-pipe row", "see a | b", lead, false, nil, nil},
		{"prose with escaped pipe, any-pipe shape", `a\|b`, any, true, []string{"a|b"}, []string{`a\|b`}},
		{"indented code-ish line", "    x | y", lead, false, nil, nil},
		// CR handling (gap-rows strips it; the other readers do not, see READERS.md)
		{"CRLF stripped by default", "| a | b |\r", lead, true, []string{"a", "b"}, []string{"a", "b"}},
		{"CRLF kept on request", "| a | b |\r", Options{KeepCR: true}, true, []string{"a", "b", "\r"}, []string{"a", "b", "\r"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cells, ok := SplitRow(c.line, c.opt)
			if ok != c.ok {
				t.Fatalf("SplitRow(%q) ok=%v want %v", c.line, ok, c.ok)
			}
			if !ok {
				return
			}
			r := Row{Padded: cells}
			if got := r.Text(); !reflect.DeepEqual(got, c.text) {
				t.Errorf("Text(%q) = %q want %q", c.line, got, c.text)
			}
			if got := r.Raw(); !reflect.DeepEqual(got, c.raw) {
				t.Errorf("Raw(%q) = %q want %q", c.line, got, c.raw)
			}
			if r.Len() != len(c.text) {
				t.Errorf("Len(%q) = %d want %d", c.line, r.Len(), len(c.text))
			}
		})
	}
}

func TestSplitRowPaddedKeepsBytes(t *testing.T) {
	cells, ok := SplitRow(`|  a\| | b  |`, Options{})
	if !ok {
		t.Fatal("not a row")
	}
	want := []string{`  a\| `, " b  "}
	if !reflect.DeepEqual(cells, want) {
		t.Fatalf("padded = %q want %q", cells, want)
	}
}

func TestUnescapeEscape(t *testing.T) {
	for _, c := range []struct{ raw, text string }{
		{`a\|b`, "a|b"}, {`a\\|b`, `a\|b`}, {`a\\\|b`, `a\\|b`}, {`\|`, "|"}, {"", ""}, {`a\b`, `a\b`}, {`\\`, `\\`},
	} {
		if got := Unescape(c.raw); got != c.text {
			t.Errorf("Unescape(%q) = %q want %q", c.raw, got, c.text)
		}
		if got := Escape(c.text); got != c.raw {
			t.Errorf("Escape(%q) = %q want %q", c.text, got, c.raw)
		}
	}
}

func TestIsSeparator(t *testing.T) {
	yes := [][]string{{"---"}, {"---", ":-:", "-:", ":--"}, {"-"}, {"--", "--"}}
	no := [][]string{nil, {}, {""}, {"--x"}, {"---", "a"}, {":"}, {"- -"}, {"::-"}, {"a"}}
	for _, c := range yes {
		if !IsSeparator(c) {
			t.Errorf("IsSeparator(%q) = false want true", c)
		}
	}
	for _, c := range no {
		if IsSeparator(c) {
			t.Errorf("IsSeparator(%q) = true want false", c)
		}
	}
}

func TestSplitRowLongRunsOfBackslashes(t *testing.T) {
	// n backslashes before a pipe: the pipe is ALWAYS escaped (kit rule), for every n >= 1.
	for n := 1; n <= 9; n++ {
		line := "| a" + strings.Repeat(`\`, n) + "| b | c |"
		cells, ok := SplitRow(line, Options{})
		if !ok {
			t.Fatalf("n=%d: not a row", n)
		}
		if len(cells) != 2 {
			t.Errorf("n=%d: %d cells %q, want 2", n, len(cells), cells)
		}
	}
}
