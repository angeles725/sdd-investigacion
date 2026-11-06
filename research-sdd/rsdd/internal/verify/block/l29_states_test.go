package block

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// typedLine is a format string the command prints as a typed state: an indented token ending in ! or ? (MISSING!,
// EMPTYHASH!, EPHEMERAL?, BACKPTR?), a -AMBIGUOUS token, or a DEGRADED line.
var typedLine = regexp.MustCompile(`^\s+(?:ERROR: .*\bDEGRADED\b|(?:%s )?DEGRADED\b|[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*[!?](?:\s|$)|[A-Z]+(?:-[A-Z]+)*-AMBIGUOUS\b)`)

// fmtVerb is one fmt verb inside a format string.
var fmtVerb = regexp.MustCompile(`%[-+# 0]*[0-9]*(?:\.[0-9]+)?[a-zA-Z]`)

// pinnedElsewhere names, for each typed state no golden can hold (it needs an unreadable input, which the frozen cases
// cannot carry), the test that asserts it. The key is a fragment of the format string; the test must contain it.
var pinnedElsewhere = map[string]string{
	"empty-digest scan DEGRADED":              "TestBlockUnreadableIsNeverClean",
	"ephemeral-path scan DEGRADED":            "TestBlockUnreadableIsNeverClean",
	"DEGRADED backptr: the sentence scan":     "TestBlockUnreadableIsNeverClean",
	"DEGRADED  %s (line count failed)":        "TestBlockUnreadableCiteIsLineCountDegraded", // the test holds "(line count failed)"
	"DEGRADED manifest scan failed":           "TestBlockUnreadableProbesAreManifestDegraded",
	"DEGRADED manifest parse failed":          "TestBlockUnreadableProbesAreManifestDegraded",
	"preserved file exists but is unreadable": "TestBlockUnreadablePreservedScriptIsManifestFail",
	") is unreadable — back-pointer":          "TestBlockUnreadableBackptrIsDegraded",
	"the candidate scan under %s failed":      "TestBlockUnreadableBackptrIsDegraded",
}

type typedState struct {
	format, at string
	re         *regexp.Regexp
}

// typedStates is every typed-state format string in the package's production files, read from the code itself:
// the first argument of a call to echo, emit or fmt.Sprintf.
func typedStates(t *testing.T) []typedState {
	t.Helper()
	files, _ := filepath.Glob("*.go")
	fset := token.NewFileSet()
	var out []typedState
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		af, err := parser.ParseFile(fset, f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		ast.Inspect(af, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok || len(call.Args) == 0 || !printer(call.Fun) {
				return true
			}
			lit, ok := call.Args[0].(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			s, err := strconv.Unquote(lit.Value)
			if err != nil || !typedLine.MatchString(s) {
				return true
			}
			parts := fmtVerb.Split(s, -1)
			for i := range parts {
				parts[i] = regexp.QuoteMeta(parts[i])
			}
			re := regexp.MustCompile(`(?m)^` + strings.Join(parts, `.*?`))
			out = append(out, typedState{s, fset.Position(lit.Pos()).String(), re})
			return true
		})
	}
	return out
}

// printer reports whether fun is b.echo, emit or fmt.Sprintf: the calls whose first argument is printed.
func printer(fun ast.Expr) bool {
	if id, ok := fun.(*ast.Ident); ok {
		return id.Name == "emit"
	}
	sel, ok := fun.(*ast.SelectorExpr)
	return ok && (sel.Sel.Name == "echo" || sel.Sel.Name == "Sprintf")
}

// TestEveryTypedStatePinned: each typed state appears in at least one golden, or is asserted by the test that
// pinnedElsewhere names. It prints what it counted, so a pass over zero states or zero goldens cannot happen.
func TestEveryTypedStatePinned(t *testing.T) {
	t.Parallel()
	states := typedStates(t)
	goldens := bkLoadGoldens(t)
	var blob strings.Builder
	for _, g := range goldens {
		blob.WriteString(g.Stdout + "\n" + g.Stderr + "\n")
	}
	tests := testSources(t)
	inGolden, elsewhere := 0, 0
	for _, s := range states {
		if s.re.MatchString(blob.String()) {
			inGolden++
			continue
		}
		name, frag, hits := "", "", 0
		for key, test := range pinnedElsewhere {
			if strings.Contains(s.format, key) {
				name, frag, hits = test, longestFragment(key), hits+1
			}
		}
		if hits > 1 {
			t.Errorf("%s: typed state %q matches %d pinnedElsewhere keys; make the keys disjoint", s.at, s.format, hits)
			continue
		}
		src, ok := tests[name]
		if name == "" || !ok || !strings.Contains(src, frag) {
			t.Errorf("%s: typed state %q is in no golden and no named test asserts it", s.at, s.format)
			continue
		}
		elsewhere++
	}
	for key := range pinnedElsewhere {
		used := false
		for _, st := range states {
			used = used || strings.Contains(st.format, key)
		}
		if !used {
			t.Errorf("pinnedElsewhere key %q matches no typed state: remove it", key)
		}
		if _, ok := tests[pinnedElsewhere[key]]; !ok {
			t.Errorf("pinnedElsewhere key %q names %s, which is not a Test function of this package", key, pinnedElsewhere[key])
		}
	}
	named := map[string]bool{}
	for _, test := range pinnedElsewhere {
		if _, ok := tests[test]; ok {
			named[test] = true
		}
	}
	t.Logf("%d typed states declared in code, %d goldens read, %d named tests found: %d pinned by a golden, %d by a named test",
		len(states), len(goldens), len(named), inGolden, elsewhere)
	if inGolden+elsewhere != len(states) && !t.Failed() {
		t.Errorf("%d golden + %d named != %d declared", inGolden, elsewhere, len(states))
	}
	if len(states) == 0 || len(goldens) == 0 {
		t.Fatalf("%d typed states, %d goldens: an empty side proves nothing", len(states), len(goldens))
	}
}

// testSources maps every Test function of the package to the text of the string literals in its body: a fragment
// left in a comment does not count as an assertion.
func testSources(t *testing.T) map[string]string {
	t.Helper()
	files, _ := filepath.Glob("*_test.go")
	out := map[string]string{}
	for _, f := range files {
		af, err := parser.ParseFile(token.NewFileSet(), f, nil, 0)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range af.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || !strings.HasPrefix(fn.Name.Name, "Test") {
				continue
			}
			var b strings.Builder
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				if lit, ok := n.(*ast.BasicLit); ok && lit.Kind == token.STRING {
					if v, err := strconv.Unquote(lit.Value); err == nil {
						b.WriteString(v + "\n")
					}
				}
				return true
			})
			out[fn.Name.Name] = b.String()
		}
	}
	return out
}

// longestFragment is the longest verb-free piece of a format fragment: the text a test of that state must contain.
func longestFragment(format string) string {
	best := ""
	for _, p := range fmtVerb.Split(format, -1) {
		if p = strings.TrimSpace(p); len(p) > len(best) {
			best = p
		}
	}
	return best
}
