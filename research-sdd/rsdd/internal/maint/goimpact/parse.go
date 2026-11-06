package goimpact

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// parseDir parses the .go files of one directory. A directory without Go files is not a package (nil).
func parseDir(m *Module, abs, rel string) (*Package, error) {
	ents, err := os.ReadDir(abs)
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range ents {
		if n := e.Name(); !e.IsDir() && strings.HasSuffix(n, ".go") {
			names = append(names, n)
		}
	}
	if len(names) == 0 {
		return nil, nil
	}
	sort.Strings(names)
	pkg := &Package{Dir: rel, Imports: map[string]bool{}, TestImports: map[string]bool{}}
	fset := token.NewFileSet()
	var prod []*ast.File
	for _, n := range names {
		isTest := strings.HasSuffix(n, "_test.go")
		f, perr := parser.ParseFile(fset, filepath.Join(abs, n), nil, parser.SkipObjectResolution)
		if perr != nil {
			if !isTest { // a test file's imports never enter the closure, so its syntax cannot change it
				pkg.ParseErrors = append(pkg.ParseErrors, filepath.ToSlash(filepath.Join(rel, n))+": "+perr.Error())
			}
			continue
		}
		recordImports(m, pkg, f, isTest)
		if !isTest {
			prod = append(prod, f)
		}
	}
	for d := range pkg.Imports {
		delete(pkg.TestImports, d)
	}
	recoverCommands(m, pkg, fset, prod)
	return pkg, nil
}

func recordImports(m *Module, pkg *Package, f *ast.File, isTest bool) {
	for _, im := range f.Imports {
		p, err := strconv.Unquote(im.Path.Value)
		if err != nil || (p != m.Path && !strings.HasPrefix(p, m.Path+"/")) {
			continue
		}
		dir := strings.TrimPrefix(strings.TrimPrefix(p, m.Path), "/")
		if isTest {
			pkg.TestImports[dir] = true
		} else {
			pkg.Imports[dir] = true
		}
	}
}

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
			if at, ok := cl.Type.(*ast.ArrayType); ok && isCmd(at.Elt) {
				for _, el := range cl.Elts {
					if c, ok := el.(*ast.CompositeLit); ok && c.Type == nil {
						lits = append(lits, c)
					}
				}
			}
			for _, c := range lits {
				if cmd, ok := literalCommand(c, consts); ok {
					pkg.Commands = append(pkg.Commands, cmd)
					continue
				}
				p := fset.Position(c.Pos())
				pkg.Unresolved = append(pkg.Unresolved, filepath.ToSlash(filepath.Join(pkg.Dir, filepath.Base(p.Filename)))+":"+strconv.Itoa(p.Line))
			}
			return true
		})
	}
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
				for i, id := range vs.Names {
					if i < len(vs.Values) {
						if s, ok := constString(vs.Values[i], nil); ok {
							out[id.Name] = s
						}
					}
				}
			}
		}
	}
	return out
}
