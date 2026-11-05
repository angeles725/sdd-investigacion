package secretscan

import (
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

// A target registered LIVE-INSTALL in the kit's TARGETS.md gets a reminder line: the SECRETS DISCIPLINE is a hard
// invariant there. The reminder is informational and never changes a verdict.

// targetBase is `basename "$target"`; "." and ".." name nothing, so the physical directory name stands in.
func targetBase(target, abs string) string {
	t := strings.TrimRight(target, "/")
	if t == "" {
		return "/"
	}
	b := path.Base(t)
	if b == "." || b == ".." {
		if real, err := filepath.EvalSymlinks(abs); err == nil {
			return filepath.Base(real)
		}
	}
	return b
}

// liveInstall reports whether a TARGETS.md line naming the target (as a whole word, case-insensitively) also says
// live-install. An absent or unreadable TARGETS.md is no banner (`2>/dev/null`).
func liveInstall(kitDir, name string) bool {
	if kitDir == "" {
		return false
	}
	src, err := os.ReadFile(filepath.Join(kitDir, "TARGETS.md"))
	if err != nil {
		return false
	}
	word, err := regexp.Compile(`(?i)\b` + regexp.QuoteMeta(name) + `\b`)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(src), "\n") {
		if word.MatchString(line) && strings.Contains(strings.ToLower(line), "live-install") {
			return true
		}
	}
	return false
}
