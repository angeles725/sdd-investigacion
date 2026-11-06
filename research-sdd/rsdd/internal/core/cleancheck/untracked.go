package cleancheck

import "strings"

// inScratch is `_in_scratch`: the path is the scratchpad or lies below it.
func (r *run) inScratch(p string) bool {
	if r.scratchP == "" {
		return false
	}
	return p == r.scratchP || strings.HasPrefix(p, strings.TrimSuffix(r.scratchP, "/")+"/")
}

// scanUntracked is class (a): every untracked, non-ignored file git lists that no keep-list glob keeps and that is
// not in the scratchpad, in git's order.
func (r *run) scanUntracked() bool {
	g := r.git("ls-files", "--others", "--exclude-standard", "-z")
	r.passthrough(g.err) // git's own diagnostics (an unreadable directory) stay visible
	if g.rc != 0 {
		return r.refuse("git ls-files failed or was truncated in " + r.target)
	}
	for _, rel := range nulFields(g.out) {
		if r.keep.kept(rel) || r.inScratch(r.targetP+"/"+rel) {
			continue
		}
		r.finding("GARBAGE untracked " + rel)
	}
	return true
}
