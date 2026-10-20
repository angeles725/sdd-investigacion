package parity

import (
	"fmt"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"
)

// This file mirrors target_paths_all from toolbelt/lib/target-paths.sh: only
// table rows (optional whitespace, then "|") are read, and three token forms
// are recognised: `/abs/path`, `$RESEARCH_HOME/rest` and
// `${RESEARCH_HOME}/rest`. Non-directory tokens and truncated paths pass
// through unchanged; the corpus runner reports the ones that do not exist.
// crosscheck_test.go keeps the two implementations in step.
var (
	rowRe  = regexp.MustCompile(`^[[:space:]]*\|`)
	absRe  = regexp.MustCompile("`(/[^`]+)`")
	homeRe = regexp.MustCompile("`\\$(?:\\{RESEARCH_HOME\\}|RESEARCH_HOME)/([^`]+)`")
)

// ResearchHome is RESEARCH_HOME, defaulting to HOME when unset or empty.
func ResearchHome(getenv func(string) string) string {
	if rh := getenv("RESEARCH_HOME"); rh != "" {
		return rh
	}
	return getenv("HOME")
}

// ParseTargets returns the sorted, de-duplicated target paths of a TARGETS.md.
// An unreadable file is an absent-input error: a confident empty list must
// never be returned for a file that was never read. A readable file with no
// table paths yields an empty list, which callers must report as empty-input.
func ParseTargets(path, researchHome string) ([]string, error) {
	if path == "" {
		return nil, fmt.Errorf("%s: TARGETS.md path not given", KindAbsentInput)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("%s: cannot read TARGETS.md %s: %w", KindAbsentInput, path, err)
	}
	rh := strings.TrimSuffix(researchHome, "/")
	var out []string
	for line := range strings.SplitSeq(string(b), "\n") {
		if !rowRe.MatchString(line) {
			continue
		}
		for _, m := range absRe.FindAllStringSubmatch(line, -1) {
			out = append(out, m[1])
		}
		for _, m := range homeRe.FindAllStringSubmatch(line, -1) {
			out = append(out, rh+"/"+m[1])
		}
	}
	sort.Strings(out)
	return slices.Compact(out), nil
}
