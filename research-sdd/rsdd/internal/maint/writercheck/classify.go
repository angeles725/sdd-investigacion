package writercheck

import (
	"fmt"
	"io"
	"strings"
)

// isProduction is the kit's one definition of a production script: a script (.sh .py .mjs .js .cjs .ts) under
// research-sdd/toolbelt, research-sdd/install or research-sdd/templates, EXCEPT suites (tests/*.test.*),
// tests/fixtures/**, other tests/ sub-directories and research-sdd/install/tests/**; the test infrastructure
// (tests/run-all.sh, suite-impact.sh, shard-join.sh, tests/lib/**) counts. .github/scripts/parse-red-evidence.cjs
// implements the same rule; tests/fixtures/kit-writer-check/production-paths.txt pins both. The rules are checked in
// this order and the first that matches decides.
func isProduction(p string) bool {
	const tests = "research-sdd/toolbelt/tests/"
	switch {
	case strings.HasPrefix(p, tests+"fixtures/"):
		return false
	case strings.HasPrefix(p, tests+"lib/"): // test infrastructure counts: skip the suite and sub-directory rules
	case strings.HasPrefix(p, tests) && strings.Contains(p[len(tests):], ".test."): // suites
		return false
	case strings.HasPrefix(p, tests) && strings.Contains(p[len(tests):], "/"): // any other tests/ sub-directory
		return false
	case strings.HasPrefix(p, "research-sdd/install/tests/"):
		return false
	case strings.HasPrefix(p, "research-sdd/toolbelt/"), strings.HasPrefix(p, "research-sdd/install/"), strings.HasPrefix(p, "research-sdd/templates/"):
	default:
		return false
	}
	for _, ext := range productionExts {
		if strings.HasSuffix(p, ext) {
			return true
		}
	}
	return false
}

// productionExts are the extensions of a script.
var productionExts = []string{".sh", ".py", ".mjs", ".js", ".cjs", ".ts"}

// classify is `--classify <path>...`: `production <path>` or `other <path>` per path.
func classify(w io.Writer, paths []string) {
	for _, p := range paths {
		kind := "other"
		if isProduction(p) {
			kind = "production"
		}
		fmt.Fprintf(w, "%s %s\n", kind, p)
	}
}
