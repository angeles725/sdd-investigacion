package kit

import (
	"errors"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

// inputReasons maps the typed input states of this package to the reason-codes.v1.md input class, in priority
// order (a more specific sentinel first).
var inputReasons = []struct {
	err  error
	code reasons.Code
}{
	{ErrAbsentInput, reasons.AbsentInput},
	{ErrUnreadable, reasons.AbsentInput}, // "not found or not traversable"
	{ErrNotDirectory, reasons.AbsentInput},
	{ErrIncomplete, reasons.AbsentInput},
	{ErrEmptyInput, reasons.EmptyInput},
	{ErrNoMatch, reasons.NoMatch},
	{ErrNoAncestor, reasons.NoMatch},
	{ErrStateAbsent, reasons.NoMatch},
	{ErrStateAmbiguous, reasons.Unclassifiable},
}

// InputReason is the registry input code of err, so a caller emits a typed state instead of reading an empty
// result as zero. Usage errors, a bad pattern and an unresolved kit are not input states: false.
func InputReason(err error) (reasons.Code, bool) {
	for _, r := range inputReasons {
		if errors.Is(err, r.err) {
			return r.code, true
		}
	}
	return reasons.Code{}, false
}
