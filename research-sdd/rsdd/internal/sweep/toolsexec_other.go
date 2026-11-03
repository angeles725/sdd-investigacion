//go:build !unix

package sweep

import "os"

// isExecutable approximates `[ -x f ]` where access(2) is missing: any execute bit of the mode.
func isExecutable(f string) bool {
	st, err := os.Stat(f)
	return err == nil && st.Mode().Perm()&0o111 != 0
}
