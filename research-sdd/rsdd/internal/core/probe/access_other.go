//go:build !unix

package probe

import "os"

// accessExec approximates `[ -x ]` where there is no execute bit: the path exists.
func accessExec(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
