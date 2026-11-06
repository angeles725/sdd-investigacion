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
	pkg := &Package{Dir: rel, Imports: map[string]bool{}, TestImports: map[string]bool{}, Refs: map[string]bool{}}
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
		p, _ := strconv.Unquote(im.Path.Value) // the parser only yields valid literals
		rest, ok := strings.CutPrefix(p+"/", m.Path+"/")
		if !ok {
			continue
		}
		dir := strings.TrimSuffix(rest, "/")
		if isTest {
			pkg.TestImports[dir] = true
		} else {
			pkg.Imports[dir] = true
		}
	}
}
