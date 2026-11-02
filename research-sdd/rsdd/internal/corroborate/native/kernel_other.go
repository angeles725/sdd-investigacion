//go:build !linux

package native

// kernelRelease has no portable source off Linux; the adapter only runs where Bubblewrap does.
func kernelRelease() string { return "unknown" }
