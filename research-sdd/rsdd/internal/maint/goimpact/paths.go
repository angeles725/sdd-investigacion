package goimpact

import (
	"path"
	"slices"
	"strings"
)

// moduleRel turns a repo-relative changed path into a module-relative one. A path outside the rsdd module
// (or not a clean relative path) returns the FULL reason instead.
func moduleRel(file string) (rel, why string) {
	rel, ok := strings.CutPrefix(path.Clean(file), ModuleDir+"/")
	if !ok {
		return "", "outside the rsdd module"
	}
	return rel, ""
}

// typedFull names the module paths whose change affects every command: the reason, or "" for any other path.
func typedFull(rel string) string {
	if why, ok := exactFull[rel]; ok {
		return why
	}
	for _, p := range prefixFull {
		if strings.HasPrefix(rel, p.prefix) {
			return p.why
		}
	}
	return ""
}

// isTestPath reports a *_test.go file or any file under a testdata directory.
func isTestPath(rel string) bool {
	return strings.HasSuffix(rel, "_test.go") || slices.Contains(strings.Split(rel, "/"), "testdata")
}
