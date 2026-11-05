//go:build !unix

package place

// Alive answers "alive" for every pid off unix: there is no signal 0 to prove a process gone, and debris is only
// removed on proof, so the stale-part sweep deletes nothing.
func Alive(string) bool { return true }
