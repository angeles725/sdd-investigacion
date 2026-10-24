package proc

// HelperCommand is the hidden first argument that turns rsdd into the rlimit
// re-exec helper (Go has no preexec hook): `rsdd __exec LIMITS PATH ARGV0
// [ARG...]` lowers each limit in LIMITS, then execs PATH with that argv.
const HelperCommand = "__exec"

// Limit lowers one resource limit (soft and hard) in the child. Resource is
// one of as, core, cpu, data, fsize, nofile, stack; a Value above the
// current hard limit is clamped to it.
type Limit struct {
	Resource string
	Value    uint64
}
