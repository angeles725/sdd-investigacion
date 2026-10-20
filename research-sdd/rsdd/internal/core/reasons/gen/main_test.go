package main

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

const header = "| code | class | emitters | meaning | continuation |\n|---|---|---|---|---|\n"

func rowLine(code, class string) string {
	return "| `" + code + "` | " + class + " | a.sh, b.sh | what it means | do `this` |"
}

func TestParseTableEdges(t *testing.T) {
	r1 := rowLine("degraded: one", "degraded")
	r2 := rowLine("degraded: two <v>", "degraded")
	r3 := rowLine("absent-input", "input")
	cases := []struct {
		name string
		md   string
		want []string
	}{
		{"single row", header + r1 + "\n", []string{"degraded: one"}},
		{"single row without trailing newline", header + r1, []string{"degraded: one"}},
		{"first middle last", "# t\n\n" + header + r1 + "\n" + r2 + "\n" + r3 + "\n\nprose\n", []string{"degraded: one", "degraded: two <v>", "absent-input"}},
		{"last row at EOF without newline", header + r1 + "\n" + r2 + "\n" + r3, []string{"degraded: one", "degraded: two <v>", "absent-input"}},
		{"two tables", header + r1 + "\n\ntext\n\n" + header + r3 + "\n", []string{"degraded: one", "absent-input"}},
		{"indented tables are not registry rows", header + r1 + "\n\n  | state | exit |\n  |---|---|\n  | `started` | 0 |\n", []string{"degraded: one"}},
		{"header-only tables are not rows", "| column | meaning |\n|---|---|\n| code | the code |\n" + header + r1 + "\n", []string{"degraded: one"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rows, err := parseTable(strings.NewReader(c.md))
			if err != nil {
				t.Fatalf("parseTable: %v", err)
			}
			if len(rows) != len(c.want) {
				t.Fatalf("got %d rows, want %d: %+v", len(rows), len(c.want), rows)
			}
			for i, w := range c.want {
				if rows[i].Code != w {
					t.Errorf("row %d code = %q, want %q", i, rows[i].Code, w)
				}
			}
		})
	}
}

func TestParseTableFields(t *testing.T) {
	rows, err := parseTable(strings.NewReader(header + rowLine("degraded: x", "degraded") + "\n"))
	if err != nil || len(rows) != 1 {
		t.Fatalf("rows=%v err=%v", rows, err)
	}
	r := rows[0]
	if r.Class != "degraded" || r.Meaning != "what it means" || r.Continuation != "do `this`" ||
		len(r.Emitters) != 2 || r.Emitters[0] != "a.sh" || r.Emitters[1] != "b.sh" {
		t.Fatalf("unexpected row %+v", r)
	}
}

func TestParseTableEscapedPipe(t *testing.T) {
	md := "| `degraded: a \\| b` | degraded | x.sh | m | c |\n"
	rows, err := parseTable(strings.NewReader(md))
	if err != nil || len(rows) != 1 || rows[0].Code != "degraded: a | b" {
		t.Fatalf("rows=%+v err=%v", rows, err)
	}
}

func TestParseTableRejects(t *testing.T) {
	cases := []struct{ name, md, wantSub string }{
		{"no rows", header, "no registry rows"},
		{"empty input", "", "no registry rows"},
		{"too few cells", "| `degraded: a` | degraded | x.sh | m |\n", "has 4 cells, want 5"},
		{"too many cells", "| `degraded: a` | degraded | x.sh | m | c | extra |\n", "has 6 cells, want 5"},
		{"no closing pipe", "| `degraded: a` | degraded | x.sh | m | c\n", "does not end with a closing pipe"},
		{"unclosed backtick code", "| `degraded: a | degraded | x.sh | m | c |\n", "not backtick-wrapped"},
		{"unknown class", "| `degraded: a` | weird | x.sh | m | c |\n", `unknown class "weird"`},
		{"empty continuation", "| `degraded: a` | degraded | x.sh | m |  |\n", "empty meaning or continuation"},
		{"empty meaning", "| `degraded: a` | degraded | x.sh |  | c |\n", "empty meaning or continuation"},
		{"empty emitters cell", "| `degraded: a` | degraded |  | m | c |\n", "has no emitters"},
		{"emitters of only commas", "| `degraded: a` | degraded | , , | m | c |\n", "has no emitters"},
		{"empty code", "| `` | degraded | x.sh | m | c |\n", "empty code"},
		{"duplicate code", rowLine("degraded: a", "degraded") + "\n" + rowLine("degraded: a", "degraded") + "\n", `duplicate code "degraded: a" (first at line 1)`},
		{"degraded prefix", rowLine("not a degraded line", "degraded") + "\n", "lacks the"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rows, err := parseTable(strings.NewReader(c.md))
			if err == nil {
				t.Fatalf("expected an error, got rows %+v", rows)
			}
			if !strings.Contains(err.Error(), c.wantSub) {
				t.Fatalf("error %q does not contain %q", err, c.wantSub)
			}
		})
	}
}

func TestRenderIsValidGoAndNamesAreUnique(t *testing.T) {
	rows := []row{
		{Code: "degraded: remote-visibility: <v> url empty", Class: "degraded", Emitters: []string{"a.sh"}, Meaning: "m", Continuation: "c"},
		{Code: "degraded: jq not found on PATH", Class: "degraded", Emitters: []string{"a.sh"}, Meaning: "m", Continuation: "c"},
		{Code: "absent-input", Class: "input", Emitters: []string{"a.sh"}, Meaning: "m", Continuation: "c"},
	}
	src, err := render(rows)
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if _, err := parser.ParseFile(token.NewFileSet(), "table_gen.go", src, 0); err != nil {
		t.Fatalf("generated source does not parse: %v\n%s", err, src)
	}
	for _, want := range []string{"DegradedRemoteVisibilityVUrlEmpty", "DegradedJqNotFoundOnPATH", "AbsentInput"} {
		if !strings.Contains(string(src), want+" ") {
			t.Errorf("generated source lacks identifier %s:\n%s", want, src)
		}
	}
	if !strings.HasPrefix(string(src), "// Code generated by gen; DO NOT EDIT.") {
		t.Error("missing generated-code header")
	}
}

func TestRenderRejectsNameCollision(t *testing.T) {
	rows := []row{
		{Code: "degraded: a b", Class: "degraded", Emitters: []string{"x"}, Meaning: "m", Continuation: "c"},
		{Code: "degraded: a-b", Class: "degraded", Emitters: []string{"x"}, Meaning: "m", Continuation: "c"},
	}
	if _, err := render(rows); err == nil {
		t.Fatal("expected a name collision error")
	}
}

func TestRenderRejectsReservedIdentifiers(t *testing.T) {
	// Hand-written exported names of package reasons that a registry code would collide with.
	for _, code := range []string{"class", "code", "all", "lookup", "render", "emit", "emit detail", "class degraded", "class input"} {
		rows := []row{{Code: code, Class: "input", Emitters: []string{"x"}, Meaning: "m", Continuation: "c"}}
		_, err := render(rows)
		if err == nil || !strings.Contains(err.Error(), "reserved") {
			t.Errorf("code %q: want a reserved-identifier error, got %v", code, err)
		}
	}
	// A near miss is fine.
	if _, err := render([]row{{Code: "classes", Class: "input", Emitters: []string{"x"}, Meaning: "m", Continuation: "c"}}); err != nil {
		t.Errorf("classes: %v", err)
	}
}
