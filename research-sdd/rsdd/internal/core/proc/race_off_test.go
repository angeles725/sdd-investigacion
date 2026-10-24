//go:build !race

package proc

// raceBuild reports whether the test binary carries the race detector, whose
// ThreadSanitizer runtime reserves more address space than a low RLIMIT_AS allows.
const raceBuild = false
