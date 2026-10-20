// Package archtest enforces the import rule of the rsdd layout.
//
// Tiers (first path segment under internal/):
//
//	core tier  cli, core, testkit  - dependency-free building blocks; may
//	                                  import only other core-tier packages
//	registry   commands            - may import anything internal (it wires
//	                                  domains into the command table)
//	domain     every other segment - may import core tier only, never
//	                                  another domain and never commands
//
// A violation fails the build, which is what keeps "adding a command = one
// file + one registry line" true.
package archtest

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

var coreTier = map[string]bool{"cli": true, "core": true, "testkit": true}

const registry = "commands"

// Result reports what was examined as well as what was found, so a zero
// cannot be mistaken for "did not look".
type Result struct {
	Packages   int
	Files      int
	Violations []string
}

// stdioFile is the only non-test file allowed to touch the ambient process
// state; everything else receives it through cli.Stdio.
const stdioFile = "cli/stdio.go"

// forbiddenCalls are the ambient reads that must stay inside stdioFile.
var forbiddenCalls = map[string]map[string]bool{
	"os":   {"Getenv": true, "LookupEnv": true, "Getwd": true},
	"time": {"Now": true},
}

// Check scans every .go file under root/internal and root/cmd (testdata
// excluded) and applies two rules: the tier import rule, and the ban on
// os.Getenv / os.LookupEnv / os.Getwd / time.Now outside internal/cli/stdio.go
// (test files are exempt). module is the module path used to recognise
// internal imports. cmd/ packages are registry-tier: they may import
// anything internal, but are still subject to the call ban.
func Check(root, module string) (Result, error) {
	var r Result
	pkgs := map[string]bool{}
	for _, sub := range []string{"internal", "cmd"} {
		dir := filepath.Join(root, sub)
		if _, err := os.Stat(dir); err != nil {
			if sub == "cmd" && os.IsNotExist(err) {
				continue
			}
			return r, fmt.Errorf("archtest: cannot read %s: %w", dir, err)
		}
		if err := scan(&r, pkgs, root, sub, module); err != nil {
			return r, err
		}
	}
	if len(pkgs) == 0 {
		return r, fmt.Errorf("archtest: no Go packages under %s (an empty scan proves nothing)", root)
	}
	r.Packages = len(pkgs)
	sort.Strings(r.Violations)
	return r, nil
}

func scan(r *Result, pkgs map[string]bool, root, sub, module string) error {
	base := filepath.Join(root, sub)
	prefix := module + "/internal/"
	fset := token.NewFileSet()
	return filepath.WalkDir(base, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		// Name packages relative to internal/, but keep the cmd/ prefix.
		nameRoot := base
		if sub == "cmd" {
			nameRoot = root
		}
		relDir, err := filepath.Rel(nameRoot, filepath.Dir(path))
		if err != nil {
			return err
		}
		relFile, _ := filepath.Rel(nameRoot, path)
		pkg, file := filepath.ToSlash(relDir), filepath.ToSlash(relFile)
		pkgs[sub+"/"+pkg] = true
		r.Files++
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return fmt.Errorf("archtest: parse %s: %w", path, err)
		}
		names := map[string]string{} // local import name -> import path (os, time only)
		for _, imp := range f.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				return fmt.Errorf("archtest: %s: bad import literal %s: %w", path, imp.Path.Value, err)
			}
			if _, watched := forbiddenCalls[p]; watched {
				local := p
				if imp.Name != nil {
					local = imp.Name.Name
				}
				names[local] = p
			}
			if sub == "internal" && strings.HasPrefix(p, prefix) {
				target := strings.TrimPrefix(p, prefix)
				if why := violation(pkg, target); why != "" {
					r.Violations = append(r.Violations, fmt.Sprintf("%s imports %s: %s (%s)", pkg, p, why, file))
				}
			}
			if sub == "cmd" && strings.HasPrefix(p, prefix) {
				continue // cmd/ is registry-tier: any internal import is allowed
			}
		}
		if file == stdioFile || strings.HasSuffix(file, "_test.go") {
			return nil
		}
		ast.Inspect(f, func(n ast.Node) bool {
			sel, ok := n.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			id, ok := sel.X.(*ast.Ident)
			if !ok {
				return true
			}
			if path, watched := names[id.Name]; watched && forbiddenCalls[path][sel.Sel.Name] {
				r.Violations = append(r.Violations, fmt.Sprintf("%s: %s.%s outside %s - take it from cli.Stdio", file, path, sel.Sel.Name, stdioFile))
			}
			return true
		})
		return nil
	})
}

func head(p string) string {
	h, _, _ := strings.Cut(p, "/")
	return h
}

// violation returns why importer -> target is forbidden, or "".
func violation(importer, target string) string {
	from, to := head(importer), head(target)
	if from == to || from == registry {
		return ""
	}
	if coreTier[from] {
		if !coreTier[to] {
			return "core tier must not import domains or commands"
		}
		return ""
	}
	if !coreTier[to] {
		return "a domain may import only the core tier, never another domain or commands"
	}
	return ""
}
