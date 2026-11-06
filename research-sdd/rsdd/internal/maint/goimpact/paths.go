package goimpact

import (
	"path"
	"strings"
)

// moduleRel turns a repo-relative changed path into a module-relative one. A path outside the rsdd module
// (or not a clean relative path) returns the FULL reason instead.
func moduleRel(file string) (rel, why string) {
	p := path.Clean(file)
	if strings.HasPrefix(file, "/") || p == ".." || strings.HasPrefix(p, "../") || !strings.HasPrefix(p, ModuleDir+"/") {
		return "", "outside the rsdd module"
	}
	return strings.TrimPrefix(p, ModuleDir+"/"), ""
}

// typedFull names the module paths whose change affects every command: the reason, or "" for any other path.
func typedFull(rel string) string {
	switch {
	case rel == "go.mod", rel == "go.sum":
		return rel + " changes the whole build"
	case rel == "teeth-debt.txt":
		return "teeth-debt.txt is read by the Go bridge suite"
	case rel == "Makefile":
		return "Makefile changes how the binary is built"
	case strings.HasPrefix(rel, "cmd/"):
		return "cmd/** is the binary entry point"
	case strings.HasPrefix(rel, "internal/cli/"):
		return "internal/cli/** is the dispatcher every command runs through"
	case strings.HasPrefix(rel, "internal/commands/"):
		return "internal/commands/** is the command registry"
	}
	return ""
}

// isTestPath reports a *_test.go file or any file under a testdata directory.
func isTestPath(rel string) bool {
	if strings.HasSuffix(rel, "_test.go") {
		return true
	}
	for _, s := range strings.Split(rel, "/") {
		if s == "testdata" {
			return true
		}
	}
	return false
}
