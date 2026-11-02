//go:build !unix

package verify

import "os"

// accessRX approximates `[ -r p ] && [ -x p ]` where access(2) does not exist: any permission bit for the
// directory counts. The kit targets unix; this keeps the cross builds compiling.
func accessRX(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().Perm()&0o500 == 0o500
}
