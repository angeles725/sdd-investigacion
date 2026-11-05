package kitgate

import (
	"strconv"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// DefaultLockTimeout is how long the gate waits for the lock when nothing says otherwise (seconds, as text).
const DefaultLockTimeout = "14400"

// MsgBadLockTimeout is the usage text for a --lock-timeout / KIT_GATE_LOCK_TIMEOUT that is not whole seconds.
const MsgBadLockTimeout = "--lock-timeout must be a number of seconds"

// maxLockSeconds bounds a timeout too long for an int: the lock is then waited for as long as one can be.
const maxLockSeconds = 1<<31 - 1

// ValidLockTimeout is true for one or more digits (the bash refused an empty value and any non-digit).
func ValidLockTimeout(v string) bool { return v != "" && kitmaint.AllDigits(v) }

// lockSeconds reads a valid timeout. Improvement over the bash (whose flock refused a value past its own range with
// an error read as a lock timeout): an overflowing number waits as long as it can instead of not at all.
func lockSeconds(v string, overflowTriesOnce bool) int {
	n, err := strconv.Atoi(v)
	if err != nil {
		if overflowTriesOnce {
			return 0
		}
		return maxLockSeconds
	}
	return min(n, maxLockSeconds)
}
