package grammar

import (
	"errors"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

// InputReason is the reason-codes.v1.md input code of a Read error, so a consumer emits a typed state instead of
// reading a failed read as "no deltas". Both read failures are absent-input ("not found or not traversable");
// any other error is not an input state: false.
func InputReason(err error) (reasons.Code, bool) {
	if errors.Is(err, ErrAbsentInput) || errors.Is(err, ErrUnreadable) {
		return reasons.AbsentInput, true
	}
	return reasons.Code{}, false
}
