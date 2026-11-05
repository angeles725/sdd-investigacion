package fetchdoc

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"

// stage seals the run at the point of no return: signals are ignored from here, a signal that arrived before is
// honoured, and the staged file is hashed BEFORE it is installed, so a hashing failure can never leave new bytes in
// sources/ without their row. It returns the sha256 of the staged file, or the exit status to stop with.
func (x *exe) stage(staged string) (sha string, code int) {
	x.sess.Block()
	if c, ok := x.sess.interrupted(); ok {
		return "", c
	}
	h := x.d.Hash
	if h == nil {
		h = srcregistry.FileSHA256
	}
	sha, err := h(staged)
	if err != nil {
		x.printf("fetch-doc: cannot hash %s: %v\n", staged, err)
		return "", exitFailure
	}
	return sha, 0
}
