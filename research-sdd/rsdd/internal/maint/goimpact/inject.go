package goimpact

import (
	"go/ast"
	"go/token"
)

// recoverInjections reads the seam assignments `x.V = y.F`, x and y in-module imports, anywhere in the non-test
// files (the registry tier does `verify.SessionBudgetRunner = budget.RunSession` in internal/commands/wire.go).
// Package y then runs inside the commands of package x, so a change in y reaches x's commands: Module.Injects
// records y -> x. Only this exact shape is read; any other way of wiring a function in is not an edge here.
func recoverInjections(m *Module, files []*ast.File) {
	for _, f := range files {
		imports := moduleImportNames(m, f)
		ast.Inspect(f, func(n ast.Node) bool {
			as, ok := n.(*ast.AssignStmt)
			if !ok || as.Tok != token.ASSIGN || len(as.Lhs) != len(as.Rhs) {
				return true
			}
			for i := range as.Lhs {
				x, okx := importedSelector(as.Lhs[i], imports)
				y, oky := importedSelector(as.Rhs[i], imports)
				if okx && oky && x != y {
					if m.Injects[y] == nil {
						m.Injects[y] = map[string]bool{}
					}
					m.Injects[y][x] = true
				}
			}
			return true
		})
	}
}

// importedSelector returns the module dir of `pkg.Name` when pkg is an in-module import.
func importedSelector(e ast.Expr, imports map[string]string) (string, bool) {
	s, ok := e.(*ast.SelectorExpr)
	if !ok {
		return "", false
	}
	id, ok := s.X.(*ast.Ident)
	if !ok {
		return "", false
	}
	dir, ok := imports[id.Name]
	return dir, ok
}
