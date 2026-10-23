package gfm

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var reAnyPipeToken = regexp.MustCompile(`\\\||\|`)

// expectedBody derives, WITHOUT calling SplitRow, the row's cell region and the number of cells it must hold.
// Independent method: tokenise with a regexp (left-to-right, `\|` first) instead of SplitRow's byte scan.
func expectedBody(line string, opt Options) (body string, cells int, ok bool) {
	if !opt.KeepCR {
		line = strings.TrimSuffix(line, "\r")
	}
	s := strings.Trim(line, " \t")
	switch opt.Shape {
	case ShapeLeadingPipe:
		if !strings.HasPrefix(s, "|") {
			return "", 0, false
		}
	case ShapeAnyPipe:
		if !strings.Contains(s, "|") {
			return "", 0, false
		}
	}
	s = strings.TrimPrefix(s, "|")
	toks := reAnyPipeToken.FindAllStringIndex(s, -1)
	var bare []int
	for _, m := range toks {
		if m[1]-m[0] == 1 {
			bare = append(bare, m[0])
		}
	}
	if n := len(bare); n > 0 && bare[n-1] == len(s)-1 {
		s = s[:len(s)-1]
		bare = bare[:n-1]
	}
	if s == "" {
		return "", 0, true
	}
	return s, len(bare) + 1, true
}

func FuzzParse(f *testing.F) {
	seeds := []string{
		"", "|", "||", "| |", "| a |", "| a | b", "| a\\| b |", "| a\\\\| b |", "| a\\\\\\| b |", "a | b", "a\\|b",
		"| a |\n|---|\n| b\\|", "| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n", "\\", "|\\", "|\\|", "|\\\\|", "\t|\ta\t|\t", "# h\n\n| x |\n|:-:|\n| ✅ |",
	}
	for _, s := range seeds {
		f.Add(s)
	}
	for _, p := range []string{"testdata/fixtures/state/RESEARCH-STATE.md", "testdata/edge/gaprows.md", "testdata/edge/focuses.md", "testdata/fixtures/sources/sources/SOURCES.md"} {
		if b, err := os.ReadFile(filepath.Clean(p)); err == nil {
			f.Add(string(b))
		}
	}
	opts := []Options{{}, {Shape: ShapeAnyPipe}, {KeepCR: true}, {Shape: ShapeAnyPipe, KeepCR: true}}
	f.Fuzz(func(t *testing.T, src string) {
		for _, opt := range opts {
			_ = ParseWith(src, opt)
			lines := strings.Split(src, "\n")
			if n := len(lines); n > 0 && lines[n-1] == "" {
				lines = lines[:n-1]
			}
			seen := map[int]bool{}
			prev := 0
			for r := range Rows(src, opt) {
				if r.Line <= prev || r.Line > len(lines) {
					t.Fatalf("line numbers not strictly increasing within 1..%d: %d after %d", len(lines), r.Line, prev)
				}
				prev = r.Line
				seen[r.Line] = true
				line := lines[r.Line-1]
				body, want, ok := expectedBody(line, opt)
				if !ok {
					t.Fatalf("Rows yielded non-row line %d %q", r.Line, line)
				}
				if r.Len() != want {
					t.Fatalf("%q (%+v): %d cells, independent count says %d", line, opt, r.Len(), want)
				}
				if got := strings.Join(r.Padded, "|"); got != body {
					t.Fatalf("%q: re-joined cell region %q != source cell region %q", line, got, body)
				}
				raw, text := r.Raw(), r.Text()
				for i := range raw {
					if Escape(Unescape(raw[i])) != raw[i] {
						t.Fatalf("%q: cell %d raw %q does not round-trip through Unescape/Escape", line, i, raw[i])
					}
					if strings.Contains(strings.ReplaceAll(raw[i], `\|`, ""), "|") {
						t.Fatalf("%q: cell %d %q holds a bare pipe", line, i, raw[i])
					}
					if Unescape(raw[i]) != text[i] {
						t.Fatalf("%q: Text/Raw disagree on cell %d", line, i)
					}
				}
			}
			for i, line := range lines {
				if _, _, ok := expectedBody(line, opt); ok && !seen[i+1] {
					t.Fatalf("row line %d %q was not yielded (%+v)", i+1, line, opt)
				}
			}
			checkDocument(t, ParseWith(src, opt))
		}
	})
}

func checkDocument(t *testing.T, d Document) {
	t.Helper()
	if (len(d.Tables) > 0) != (d.State == StateTables) {
		t.Fatalf("state %v inconsistent with %d tables", d.State, len(d.Tables))
	}
	prev := 0
	for _, tb := range d.Tables {
		if (tb.Header == nil) != (tb.Separator == nil) {
			t.Fatalf("header/separator presence mismatch: %+v", tb)
		}
		var all []Row
		if tb.Header != nil {
			all = append(all, *tb.Header, *tb.Separator)
			if tb.Header.Sep || !tb.Separator.Sep {
				t.Fatalf("header/separator flags wrong: %+v", tb)
			}
		}
		all = append(all, tb.Rows...)
		for _, r := range all {
			if r.Line <= prev {
				t.Fatalf("table rows out of order at line %d", r.Line)
			}
			prev = r.Line
		}
	}
}
