//go:build !unix

package cleancheck

// pidGone cannot probe a pid off unix; the engine's bounded children are unsupported there (proc.ErrUnsupported).
func pidGone(int) bool { return true }
