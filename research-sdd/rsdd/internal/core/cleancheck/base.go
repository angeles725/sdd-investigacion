package cleancheck

import "strings"

// baseRef is the branch scan's base: the commit the merged test runs against, the name printed for it, and its
// full ref name (empty for a raw hash), which hides the base's own branch and its twins.
type baseRef struct {
	commit, label, full string
}

func (b baseRef) found() bool { return b.commit != "" }

// resolveBase settles the base before any scan prints a line, so a bad --base is exit 2 with nothing else printed.
func (r *run) resolveBase() bool {
	if arg := r.o.Base; arg != "" {
		g := r.git("rev-parse", "--verify", "-q", arg+"^{commit}")
		if g.rc != 0 {
			return r.refuse("--base ref not found or not a commit: " + arg)
		}
		r.base = baseRef{commit: g.trimmed(), label: arg, full: r.git("rev-parse", "--symbolic-full-name", arg).trimmed()}
		return true
	}
	full := ""
	if sym := r.git("symbolic-ref", "-q", "refs/remotes/origin/HEAD"); sym.rc == 0 && sym.trimmed() != "" && r.commitOf(sym.trimmed()) != "" {
		full = sym.trimmed()
	} else if r.commitOf("refs/heads/main") != "" {
		full = "refs/heads/main"
	} else if r.commitOf("refs/heads/master") != "" {
		full = "refs/heads/master"
	}
	if full == "" {
		return true
	}
	label := strings.TrimPrefix(strings.TrimPrefix(full, "refs/remotes/"), "refs/heads/")
	r.base = baseRef{commit: r.commitOf(full), label: label, full: full}
	return true
}

// commitOf is the commit a ref names, or empty.
func (r *run) commitOf(ref string) string {
	g := r.git("rev-parse", "--verify", "-q", ref+"^{commit}")
	if g.rc != 0 {
		return ""
	}
	return g.trimmed()
}
