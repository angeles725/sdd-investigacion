package writercheck

import "fmt"

// scanned reports whether the name-kill scan reads a file (by extension) and whether it is a python/js/ts script,
// where the argv-list and call forms count too.
func scanned(file string) (scan, script bool) {
	return reScanned.MatchString(file), reScripts.MatchString(file)
}

// isNameKill is the verdict for ONE added line of a scanned file: a comment-only line and a line carrying the allow
// marker are never kills; otherwise any of the name-kill forms is.
func isNameKill(line string, script bool) bool {
	if reComment.MatchString(line) || reAllow.MatchString(line) {
		return false
	}
	return reByName.MatchString(line) || (script && (reArgv.MatchString(line) || reCall.MatchString(line))) ||
		reKillAll.MatchString(line) || rePipeKill.MatchString(line) || reSubKill.MatchString(line)
}

// scanNameKills is the scan over the ADDED lines of a diff: one `name-kill <file>:<line>` finding per offending line,
// in the order of the lines.
func scanNameKills(added []addedLine) []finding {
	var out []finding
	for _, a := range added {
		scan, script := scanned(a.file)
		if !scan || !isNameKill(a.text, script) {
			continue
		}
		out = append(out, finding{kind: "name-kill", subject: fmt.Sprintf("%s:%d", a.file, a.line), detail: "name-based process kill"})
	}
	return out
}
