//go:build !unix

package java

// runAdapter needs process groups and Bubblewrap, which exist only on Unix hosts.
func (e *env) runAdapter(command []string, cwd, engineRoot string, environment []string, timeoutSec int, maxFiles, maxBytes int64) (outcome, error) {
	return outcome{}, fail("network-denied isolation cannot be established")
}
