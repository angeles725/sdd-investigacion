package git

import "strings"

// repositorySelectors are the variables that point git at a repository other than the one named by -C.
var repositorySelectors = map[string]bool{"GIT_DIR": true, "GIT_WORK_TREE": true, "GIT_COMMON_DIR": true, "GIT_INDEX_FILE": true}

// WithoutSelectors is env without GIT_DIR, GIT_WORK_TREE, GIT_COMMON_DIR and GIT_INDEX_FILE, so that a caller's
// environment cannot override the repository a run names with -C. For a name that appears more than once only the
// last entry is kept, the one exec reads. The result is never nil: a nil Env would leave a child to inherit.
func WithoutSelectors(env []string) []string {
	last := map[string]int{}
	for i, kv := range env {
		if k, _, ok := strings.Cut(kv, "="); ok {
			last[k] = i
		}
	}
	out := make([]string, 0, len(env))
	for i, kv := range env {
		k, _, ok := strings.Cut(kv, "=")
		if ok && (repositorySelectors[k] || last[k] != i) {
			continue
		}
		out = append(out, kv)
	}
	return out
}
