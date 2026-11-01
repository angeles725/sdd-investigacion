//go:build !unix

package hook

import "os"

const (
	accR = 4
	accX = 1
)

// accessOK approximates access(2) on platforms without it: the path resolves and, for execute, a mode bit is set.
func accessOK(path string, mode uint32) bool {
	st, err := os.Stat(path)
	if err != nil {
		return false
	}
	return mode&accX == 0 || st.Mode()&0o111 != 0
}
