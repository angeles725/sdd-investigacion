//go:build nodiff

package writercheck

import "strings"

func init() {
	// No bash oracle in the mutation run: the header comes from the Go command, whose agreement with the legacy
	// script the differential build proves (and the goldens pin through every scenario that reads a log).
	headerOf = func(k *kase, worktree bool) string {
		args := []string{"--repo", k.dir, "--base", "base", "--print-binding"}
		if worktree {
			args = append(args, "--worktree")
		}
		r := k.goRun(nil, args...)
		if r.rc != 0 {
			k.t.Fatalf("--print-binding: rc %d: %s", r.rc, r.err)
		}
		return strings.TrimSuffix(r.out, "\n")
	}
}
