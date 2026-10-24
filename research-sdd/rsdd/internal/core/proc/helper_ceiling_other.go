//go:build unix && !darwin

package proc

// platformCeiling sets no ceiling: Linux accepts any value up to the hard
// limit. On another unix whose kernel refuses a value under the hard limit,
// setrlimit's EINVAL is the helper's typed 125 failure, never skipped.
func platformCeiling(int) (uint64, bool) { return 0, false }
