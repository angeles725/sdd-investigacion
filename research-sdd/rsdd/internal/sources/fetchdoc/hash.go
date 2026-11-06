package fetchdoc

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"

// stage hashes the staged file and then seals the run at the point of no return. The hash comes BEFORE the install,
// so a hashing failure can never leave new bytes in sources/ without their row. Signals are ignored only from Block
// on (the install and the row write): one that arrives earlier, the time spent hashing included, is honoured here.
// It returns the sha256 of the staged file, or the exit status to stop with.
func (x *exe) stage(staged string) (sha string, code int) {
	h := x.d.Hash
	if h == nil {
		h = srcregistry.FileSHA256
	}
	sha, err := h(staged)
	x.sess.Block()
	if c, ok := x.sess.interrupted(); ok {
		return "", c
	}
	if err != nil {
		x.printf("fetch-doc: cannot hash %s: %v\n", staged, err)
		return "", exitFailure
	}
	return sha, 0
}
