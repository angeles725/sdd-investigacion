package goimpact

import (
	"bytes"
	"go/ast"
	"go/printer"
	"go/token"
	"path/filepath"
	"strconv"
	"strings"
)

// recoverTables reads every package-level command table of the non-test files: a variable declared as
// []cli.Command, named Commands (every domain exposes one), or initialised from an expression that holds a
// []cli.Command type. Its initializer, and every assignment to it inside a function (an init), must be readable:
// a []cli.Command literal (its elements are read by recoverCommands), append of readable arguments, the
// conversion []cli.Command(nil), another table of the package, or `x.Name` of an in-module import (recorded in
// Refs). Anything else, a wrapper call, an index, a method call, a func literal, is not attributable: it is
// recorded as Unresolved with file:line and the expression, so the FULL reason names both.
func recoverTables(m *Module, pkg *Package, fset *token.FileSet, files []*ast.File) {
	cliPath := m.Path + "/internal/cli"
	tables := map[string]bool{}
	for _, f := range files {
		local := cliLocalName(f, cliPath)
		for _, spec := range varSpecs(f) {
			for i, n := range spec.Names {
				if isTableDecl(spec, i, local) {
					tables[n.Name] = true
				}
			}
		}
	}
	for _, f := range files {
		r := tableReader{pkg: pkg, fset: fset, tables: tables, imports: moduleImportNames(m, f), local: cliLocalName(f, cliPath)}
		for _, spec := range varSpecs(f) {
			for i, n := range spec.Names {
				if tables[n.Name] && i < len(spec.Values) {
					r.require(spec.Values[i])
				}
			}
		}
		ast.Inspect(f, func(n ast.Node) bool {
			as, ok := n.(*ast.AssignStmt)
			if !ok || as.Tok != token.ASSIGN || len(as.Lhs) != len(as.Rhs) {
				return true
			}
			for i, l := range as.Lhs {
				if id, ok := l.(*ast.Ident); ok && tables[id.Name] {
					r.require(as.Rhs[i])
				}
			}
			return true
		})
	}
}

// varSpecs lists the package-level var specs of a file.
func varSpecs(f *ast.File) []*ast.ValueSpec {
	var out []*ast.ValueSpec
	for _, d := range f.Decls {
		if g, ok := d.(*ast.GenDecl); ok && g.Tok == token.VAR {
			for _, sp := range g.Specs {
				out = append(out, sp.(*ast.ValueSpec))
			}
		}
	}
	return out
}

func isTableDecl(spec *ast.ValueSpec, i int, local string) bool {
	if spec.Names[i].Name == "Commands" || (spec.Type != nil && holdsCommandSlice(spec.Type, local)) {
		return true
	}
	return i < len(spec.Values) && holdsCommandSlice(spec.Values[i], local)
}

// holdsCommandSlice reports a []cli.Command type expression anywhere inside e.
func holdsCommandSlice(e ast.Node, local string) bool {
	found := false
	ast.Inspect(e, func(n ast.Node) bool {
		if at, ok := n.(*ast.ArrayType); ok && at.Len == nil && isCliCommand(at.Elt, local) {
			found = true
		}
		return !found
	})
	return found
}

// isCliCommand reports the selector `<local>.Command`, local being the file's name for the cli package.
func isCliCommand(e ast.Expr, local string) bool {
	s, ok := e.(*ast.SelectorExpr)
	if !ok || local == "" {
		return false
	}
	id, ok := s.X.(*ast.Ident)
	return ok && id.Name == local && s.Sel.Name == "Command"
}

type tableReader struct {
	pkg     *Package
	fset    *token.FileSet
	tables  map[string]bool
	imports map[string]string
	local   string
}

// require marks e Unresolved unless it is readable.
func (r tableReader) require(e ast.Expr) {
	if !r.readable(e) {
		markUnresolved(r.pkg, r.fset, e)
	}
}

func (r tableReader) readable(e ast.Expr) bool {
	switch v := e.(type) {
	case *ast.ParenExpr:
		return r.readable(v.X)
	case *ast.CompositeLit:
		at, ok := v.Type.(*ast.ArrayType)
		return ok && isCliCommand(at.Elt, r.local) // its elements are read by recoverCommands
	case *ast.Ident:
		return v.Name == "nil" || r.tables[v.Name]
	case *ast.SelectorExpr:
		return refElement(v, r.imports, r.pkg, nil)
	case *ast.CallExpr:
		if at, ok := v.Fun.(*ast.ArrayType); ok { // []cli.Command(nil)
			return isCliCommand(at.Elt, r.local) && len(v.Args) == 1 && r.readable(v.Args[0])
		}
		if fn, ok := v.Fun.(*ast.Ident); ok && fn.Name == "append" && len(v.Args) > 0 {
			for _, a := range v.Args {
				if !r.readable(a) {
					return false
				}
			}
			return true
		}
	}
	return false
}

// markUnresolved records n as file:line: expression, the expression on one line and capped.
func markUnresolved(pkg *Package, fset *token.FileSet, n ast.Node) {
	p := fset.Position(n.Pos())
	where := filepath.ToSlash(filepath.Join(pkg.Dir, filepath.Base(p.Filename))) + ":" + strconv.Itoa(p.Line)
	var buf bytes.Buffer
	if printer.Fprint(&buf, fset, n) != nil {
		buf.Reset()
	}
	expr := strings.Join(strings.Fields(buf.String()), " ")
	if len(expr) > 80 {
		expr = expr[:80] + "..."
	}
	pkg.Unresolved = append(pkg.Unresolved, where+": "+expr)
}
