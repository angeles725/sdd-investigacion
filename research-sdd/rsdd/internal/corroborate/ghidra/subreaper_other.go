//go:build unix && !linux

package ghidra

// setSubreaper has no equivalent off Linux: descendants that leave the group are not adopted.
func setSubreaper() {}
