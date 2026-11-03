package archtest

import (
	"errors"
	"fmt"
	"go/ast"
	"go/build"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// OracleResult reports what CheckOracleTags examined as well as what it found,
// so a zero cannot be mistaken for "did not look".
type OracleResult struct {
	Scanned  int      // _test.go files parsed
	Oracles  []string // files that exec an oracle (module-relative, sorted)
	Untagged []string // oracle files still built under -tags nodiff and not allowlisted
	Stale    []string // allowlisted files that no longer need the entry
}

// CheckOracleTags enforces the teeth rule for oracle tests: a _test.go file
// that execs a legacy oracle (a Python interpreter, a .py script, or a frozen
// script under testdata/legacy) must be excluded by the nodiff build tag, or
// every mutant of `make teeth` (TEETHTAGS=nodiff) reruns the oracle.
//
// A file execs an oracle when it calls exec.Command or exec.CommandContext and
// a string literal in it (comments do not count) is "python3"/"python3.N", ends
// in ".py", or contains "testdata/legacy". allow maps a module-relative path to
// the reason it is exempt; an entry whose file is tagged, gone, or not an oracle
// file is reported Stale so the list only shrinks.
func CheckOracleTags(root string, allow map[string]string) (OracleResult, error) {
	var r OracleResult
	seen := map[string]bool{}
	for _, sub := range []string{"internal", "cmd"} {
		dir := filepath.Join(root, sub)
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				if d.Name() == "testdata" {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			oracle, excluded, err := classify(path)
			if err != nil {
				return err
			}
			r.Scanned++
			if !oracle {
				return nil
			}
			r.Oracles = append(r.Oracles, rel)
			if excluded {
				return nil
			}
			if _, ok := allow[rel]; ok {
				seen[rel] = true
				return nil
			}
			r.Untagged = append(r.Untagged, rel)
			return nil
		})
		if err != nil && !(sub == "cmd" && errors.Is(err, fs.ErrNotExist)) {
			return r, fmt.Errorf("archtest: scan %s: %w", dir, err)
		}
	}
	if r.Scanned == 0 {
		return r, fmt.Errorf("archtest: no _test.go file under %s", root)
	}
	for p := range allow {
		if !seen[p] {
			r.Stale = append(r.Stale, p)
		}
	}
	sort.Strings(r.Oracles)
	sort.Strings(r.Untagged)
	sort.Strings(r.Stale)
	return r, nil
}

// teethBuild is the build `make teeth` runs: linux/amd64 with -tags nodiff.
// MatchFile applies both the //go:build line and the _GOOS/_GOARCH file-name
// suffix, exactly as the go command does.
var teethBuild = func() build.Context {
	c := build.Default // only for ReleaseTags (go1.N), which follow the toolchain
	c.GOOS, c.GOARCH, c.Compiler, c.BuildTags = "linux", "amd64", "gc", []string{"nodiff"}
	c.CgoEnabled, c.ToolTags = false, nil // never the host's CGO_ENABLED or GOEXPERIMENT
	return c
}()

// classify parses one test file and reports whether it execs an oracle and
// whether the teeth build leaves it out.
func classify(path string) (oracle, excluded bool, err error) {
	in, err := teethBuild.MatchFile(filepath.Dir(path), filepath.Base(path))
	if err != nil {
		return false, false, err
	}
	f, err := parser.ParseFile(token.NewFileSet(), path, nil, 0)
	if err != nil {
		return false, false, err
	}
	// The local name of os/exec, whatever the file imports it as.
	execName := ""
	for _, im := range f.Imports {
		if im.Path.Value == `"os/exec"` {
			execName = "exec"
			if im.Name != nil {
				execName = im.Name.Name
			}
		}
	}
	execs, marker := false, false
	ast.Inspect(f, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.SelectorExpr:
			if id, ok := n.X.(*ast.Ident); ok && id.Name == execName && (n.Sel.Name == "Command" || n.Sel.Name == "CommandContext") {
				execs = true
			}
		case *ast.BasicLit:
			if n.Kind == token.STRING {
				if s, err := strconv.Unquote(n.Value); err == nil && isOracleMarker(s) {
					marker = true
				}
			}
		}
		return true
	})
	return execs && marker, !in, nil
}

func isOracleMarker(s string) bool {
	if s == "python3" || strings.HasPrefix(s, "python3.") {
		return true
	}
	return strings.HasSuffix(s, ".py") || strings.Contains(s, "testdata/legacy")
}
