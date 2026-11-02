//go:build !unix

package kaitai

// canExec has no execute bit to read here: a regular file counts.
func canExec(string) bool { return true }
