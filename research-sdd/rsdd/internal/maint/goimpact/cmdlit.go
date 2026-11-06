package goimpact

import (
	"go/ast"
	"go/token"
	"path"
	"path/filepath"
	"strconv"
	"strings"
)

// recoverCommands finds every cli.Command composite literal in the non-test files: written in full
// (`cli.Command{...}`), or elided inside a `[]cli.Command{{...}}` slice. Group and Name must be string
// literals or package-level string constants; anything else is recorded as Unresolved.
func recoverCommands(m *Module, pkg *Package, fset *token.FileSet, files []*ast.File) {
	consts := packageConsts(files)
	cliPath := m.Path + "/internal/cli"
	for _, f := range files {
		local := cliLocalName(f, cliPath)
		if local == "" {
			continue
		}
		imports := moduleImportNames(m, f)
		isCmd := func(e ast.Expr) bool {
			s, ok := e.(*ast.SelectorExpr)
			if !ok {
				return false
			}
			id, ok := s.X.(*ast.Ident)
			return ok && id.Name == local && s.Sel.Name == "Command"
		}
		ast.Inspect(f, func(n ast.Node) bool {
			cl, ok := n.(*ast.CompositeLit)
			if !ok {
				return true
			}
			var lits []*ast.CompositeLit
			if cl.Type != nil && isCmd(cl.Type) {
				lits = append(lits, cl)
			}
			unresolved := func(n ast.Node) {
				p := fset.Position(n.Pos())
				pkg.Unresolved = append(pkg.Unresolved, filepath.ToSlash(filepath.Join(pkg.Dir, filepath.Base(p.Filename)))+":"+strconv.Itoa(p.Line))
			}
			if at, ok := cl.Type.(*ast.ArrayType); ok && isCmd(at.Elt) {
				for _, el := range cl.Elts {
					c, ok := el.(*ast.CompositeLit)
					if ok && c.Type == nil {
						lits = append(lits, c)
						continue
					}
					if !ok && !refElement(el, imports, pkg) {
						unresolved(el)
					}
				}
			}
			for _, c := range lits {
				if cmd, ok := literalCommand(c, consts); ok {
					pkg.Commands = append(pkg.Commands, cmd)
					continue
				}
				unresolved(c)
			}
			return true
		})
	}
}

// refElement records a non-literal element of a []cli.Command slice: a package-level variable of this package
// (its literal is recovered here) or `x.Name` of an imported module package (a reference to that package's
// commands). Anything else, a call or an unknown selector, is not attributable and returns false.
func refElement(el ast.Expr, imports map[string]string, pkg *Package) bool {
	if _, ok := el.(*ast.Ident); ok {
		return true
	}
	s, ok := el.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	id, ok := s.X.(*ast.Ident)
	if !ok {
		return false
	}
	dir, ok := imports[id.Name]
	if ok {
		pkg.Refs[dir] = true
	}
	return ok
}

// moduleImportNames maps the local name of every in-module import of f to its module-relative dir. An unnamed
// import is known by the last element of its path, the repository's package-naming convention.
func moduleImportNames(m *Module, f *ast.File) map[string]string {
	out := map[string]string{}
	for _, im := range f.Imports {
		p, _ := strconv.Unquote(im.Path.Value)
		dir, ok := strings.CutPrefix(p, m.Path+"/")
		if !ok {
			continue
		}
		name := path.Base(dir)
		if im.Name != nil {
			name = im.Name.Name
		}
		out[name] = dir
	}
	return out
}

func cliLocalName(f *ast.File, cliPath string) string {
	for _, im := range f.Imports {
		if p, _ := strconv.Unquote(im.Path.Value); p == cliPath {
			if im.Name != nil {
				return im.Name.Name
			}
			return "cli"
		}
	}
	return ""
}

func literalCommand(c *ast.CompositeLit, consts map[string]string) (Command, bool) {
	var cmd Command
	haveName := false
	for _, el := range c.Elts {
		kv, ok := el.(*ast.KeyValueExpr)
		if !ok {
			return Command{}, false // positional literal: field meaning is not read here
		}
		key, _ := kv.Key.(*ast.Ident)
		if key == nil || (key.Name != "Name" && key.Name != "Group") {
			continue
		}
		v, ok := constString(kv.Value, consts)
		if !ok {
			return Command{}, false
		}
		if key.Name == "Name" {
			cmd.Name, haveName = v, true
		} else {
			cmd.Group = v
		}
	}
	return cmd, haveName && cmd.Name != ""
}

func constString(e ast.Expr, consts map[string]string) (string, bool) {
	switch v := e.(type) {
	case *ast.BasicLit:
		if v.Kind != token.STRING {
			return "", false
		}
		s, err := strconv.Unquote(v.Value)
		return s, err == nil
	case *ast.Ident:
		s, ok := consts[v.Name]
		return s, ok
	}
	return "", false
}

// packageConsts collects package-level `const X = "literal"` declarations.
func packageConsts(files []*ast.File) map[string]string {
	out := map[string]string{}
	for _, f := range files {
		for _, d := range f.Decls {
			g, ok := d.(*ast.GenDecl)
			if !ok || g.Tok != token.CONST {
				continue
			}
			for _, sp := range g.Specs {
				vs := sp.(*ast.ValueSpec)
				for i := range min(len(vs.Names), len(vs.Values)) { // an implicit repeat has no values
					if s, ok := constString(vs.Values[i], nil); ok {
						out[vs.Names[i].Name] = s
					}
				}
			}
		}
	}
	return out
}
