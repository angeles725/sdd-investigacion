package goimpact_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"runtime"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

var domainOf = regexp.MustCompile(`/internal/([^/.]+)[/.]`)

// handlerDomain is the internal/<domain> package a command's Run handler is defined in, read from the
// function's own symbol name (independent of the parser under test).
func handlerDomain(t *testing.T, run any) (domain, file string) {
	t.Helper()
	f := runtime.FuncForPC(reflect.ValueOf(run).Pointer())
	if f == nil {
		t.Fatal("a Run handler without a symbol")
	}
	m := domainOf.FindStringSubmatch(f.Name())
	if m == nil {
		t.Fatalf("handler %s is not under internal/", f.Name())
	}
	file, _ = f.FileLine(f.Entry())
	return m[1], file
}

// commandsVarFile finds, by parsing, the file of internal/<domain> (its own directory) that declares the
// package-level `var Commands`.
func commandsVarFile(t *testing.T, root, domain string) string {
	t.Helper()
	dir := filepath.Join(root, "research-sdd", "rsdd", "internal", domain)
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		n := e.Name()
		if e.IsDir() || !strings.HasSuffix(n, ".go") || strings.HasSuffix(n, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), filepath.Join(dir, n), nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range f.Decls {
			g, ok := d.(*ast.GenDecl)
			if !ok || g.Tok != token.VAR {
				continue
			}
			for _, sp := range g.Specs {
				for _, id := range sp.(*ast.ValueSpec).Names {
					if id.Name == "Commands" {
						return "research-sdd/rsdd/internal/" + domain + "/" + n
					}
				}
			}
		}
	}
	return ""
}

// realAnalysis is the engine over the real tree, built once.
func realAnalysis(t *testing.T, root string) *goimpact.Analysis {
	t.Helper()
	m, err := goimpact.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	known := map[goimpact.Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	bash, err := goimpact.ScanBash(root, func(c goimpact.Command) bool { return known[c] })
	if err != nil {
		t.Fatal(err)
	}
	return goimpact.NewAnalysis(m, bash, goimpact.DefaultWide)
}

// attributed reports FULL, or a SHIM or UNREACHED line naming the command, among the lines of one file.
func attributed(lines []string, want string) bool {
	for _, l := range lines {
		f := strings.Split(l, "\t")
		if f[0] == "FULL" || ((f[0] == "SHIM" || f[0] == "UNREACHED") && strings.HasSuffix(l, "\t"+want)) {
			return true
		}
	}
	return false
}

// Attribution over the real registry (verifier B1): for every registered command, the file declaring its
// domain's `var Commands` must answer FULL, or SHIM or UNREACHED naming that command. The registry test
// TestParserMatchesAssembledRegistry compares the SET of commands; this one compares who they are attributed to,
// so a table form the parser cannot read (append(...), an alias) cannot silently drop a command. A handler that
// lives in the shared internal/core is registered by some domain table: any of them may name it.
func TestEveryCommandIsAttributedToItsDomainTable(t *testing.T) {
	root := realRepo(t)
	a := realAnalysis(t, root)
	answers := map[string][]string{}
	answer := func(table string) []string {
		if answers[table] == nil {
			answers[table] = a.Classify(table)
		}
		return answers[table]
	}
	var allTables []string
	ents, _ := os.ReadDir(filepath.Join(root, "research-sdd", "rsdd", "internal"))
	for _, e := range ents {
		if f := commandsVarFile(t, root, e.Name()); e.IsDir() && f != "" {
			allTables = append(allTables, f)
		}
	}
	checked := 0
	for _, c := range commands.Table {
		domain, file := handlerDomain(t, c.Run)
		if domain == "commands" { // the registry's own version command: the registry file is FULL by class
			continue
		}
		want, tables := label(c), allTables
		if domain != "core" {
			table := commandsVarFile(t, root, domain)
			if table == "" {
				t.Errorf("%s: handler in %s, but internal/%s declares no `var Commands`", want, file, domain)
				continue
			}
			tables = []string{table}
		}
		ok := false
		for _, table := range tables {
			ok = ok || attributed(answer(table), want)
		}
		if !ok {
			t.Errorf("%s: %v answer neither FULL nor a SHIM/UNREACHED naming it", want, tables)
		}
		checked++
	}
	if checked < 50 {
		t.Fatalf("only %d commands were checked: the registry looks truncated", checked)
	}
}
