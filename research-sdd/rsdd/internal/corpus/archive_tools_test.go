package corpus

import "os/exec"

// archiveHaveTools reports the first tool the archive cases need that is missing from PATH ("" when all are there).
// It lives in a file that never calls exec.Command: the oracle-tag rule (internal/testkit/archtest) flags a file that
// pairs an exec call with a "python3" literal, and the Go-side cases are built under -tags nodiff.
func archiveHaveTools() string {
	for _, b := range []string{"bash", "git", "python3", "cp"} {
		if _, err := exec.LookPath(b); err != nil {
			return b + " not found"
		}
	}
	return ""
}
