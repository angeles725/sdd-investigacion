package cleancheck

// walkTree visits every entry below root in name order (pre-order), never following a symlink: it is find. depth is
// the entry's distance from root (its children are 1); a directory at maxDepth is not read (maxDepth < 0 means no
// limit). visit says whether to descend into a directory. A directory that cannot be read is collected and the walk
// goes on, as find does; one that vanished is left out.
func walkTree(root string, maxDepth int, visit func(path string, depth int, e entry) (descend bool)) []findError {
	var errs []findError
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		ents, err := listDir(dir)
		if err != nil {
			if !vanished(err) {
				errs = append(errs, newFindError(dir, err))
			}
			return
		}
		for _, e := range ents {
			p := join(dir, e.name)
			if visit(p, depth+1, e) && e.info.IsDir() && (maxDepth < 0 || depth+1 < maxDepth) {
				walk(p, depth+1)
			}
		}
	}
	walk(root, 0)
	return errs
}

// findStderr is the diagnostics of a failed walk as find printed them, one line each.
func findStderr(errs []findError) []string {
	lines := make([]string, len(errs))
	for i, e := range errs {
		lines[i] = e.line()
	}
	return lines
}
