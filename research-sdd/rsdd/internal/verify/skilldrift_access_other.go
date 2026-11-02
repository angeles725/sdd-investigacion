//go:build !unix

package verify

import "os"

// readableOS and executableOS approximate `[ -r p ]` and `[ -x p ]` where access(2) does not exist: any
// permission bit of the class counts. The kit targets unix; this keeps the cross builds compiling.
func readableOS(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().Perm()&0o444 != 0
}

func executableOS(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().Perm()&0o111 != 0
}
