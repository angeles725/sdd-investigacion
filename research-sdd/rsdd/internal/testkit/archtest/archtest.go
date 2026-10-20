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
	"go/parser"
	"go/token"
	"io/fs"
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

// Check scans every .go file under internalDir (the module's internal/
// directory, testdata excluded) and applies the tier rule. module is the
// module path used to recognise internal imports.
func Check(internalDir, module string) (Result, error) {
	var r Result
	pkgs := map[string]bool{}
	prefix := module + "/internal/"
	fset := token.NewFileSet()
	err := filepath.WalkDir(internalDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "testdata" && path != internalDir {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") {
			return nil
		}
		rel, err := filepath.Rel(internalDir, filepath.Dir(path))
		if err != nil {
			return err
		}
		pkg := filepath.ToSlash(rel)
		pkgs[pkg] = true
		r.Files++
		f, err := parser.ParseFile(fset, path, nil, parser.ImportsOnly)
		if err != nil {
			return fmt.Errorf("archtest: parse %s: %w", path, err)
		}
		for _, imp := range f.Imports {
			p, err := strconv.Unquote(imp.Path.Value)
			if err != nil {
				return fmt.Errorf("archtest: %s: bad import literal %s: %w", path, imp.Path.Value, err)
			}
			if !strings.HasPrefix(p, prefix) {
				continue
			}
			target := strings.TrimPrefix(p, prefix)
			if why := violation(pkg, target); why != "" {
				r.Violations = append(r.Violations, fmt.Sprintf("%s imports %s: %s (%s)", pkg, p, why, filepath.ToSlash(path)))
			}
		}
		return nil
	})
	if err != nil {
		return r, fmt.Errorf("archtest: walk %s: %w", internalDir, err)
	}
	if len(pkgs) == 0 {
		return r, fmt.Errorf("archtest: no Go packages under %s (an empty scan proves nothing)", internalDir)
	}
	r.Packages = len(pkgs)
	sort.Strings(r.Violations)
	return r, nil
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
