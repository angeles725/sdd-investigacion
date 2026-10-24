package gh

// State is the typed outcome of a probe or a bounded run (GHV_STATE).
type State string

// The decided visibilities: the only states a caller may act on as an answer.
const (
	StatePublic   State = "PUBLIC"
	StatePrivate  State = "PRIVATE"
	StateInternal State = "INTERNAL"
)

// The undecided states. Every one of them means "unknown", never PRIVATE.
const (
	// StateOK is a bounded Run whose gh exited 0.
	StateOK State = "OK"
	// StateTimeout is gh exceeding the bound (or exiting 124, which timeout(1) cannot tell apart).
	StateTimeout State = "TIMEOUT"
	// StateMissing is a gh binary that is not on PATH (or not there at the given path).
	StateMissing State = "GH_MISSING"
	// StateError is gh exiting non-zero, or a gh that could not be started in its directory.
	StateError State = "GH_ERROR"
	// StateUnrecognised is a probe whose gh exited 0 with an answer that is not one of the three.
	StateUnrecognised State = "UNRECOGNISED"
	// StateProbeFailed is a run core/proc refused or could not finish; the returned error says why.
	StateProbeFailed State = "PROBE_FAILED"
	// StateOutputCap is gh's output reaching Options.MaxBytes; the run was stopped there.
	StateOutputCap State = "OUTPUT_CAP"
)

// Decided reports whether s is a visibility answer (PUBLIC, PRIVATE or INTERNAL).
func (s State) Decided() bool {
	return s == StatePublic || s == StatePrivate || s == StateInternal
}
