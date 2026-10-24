package kit

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

func TestInputReason(t *testing.T) {
	_, nwErr := NestedWorktreeRoots(t.TempDir() + "/missing")
	_, _, kitErr := ResolveKitScript("/abs", envOf(nil))
	for err, want := range map[error]string{
		ErrAbsentInput: "absent-input", ErrUnreadable: "absent-input", nwErr: "absent-input", ErrIncomplete: "absent-input",
		ErrEmptyInput: "empty-input", ErrNoMatch: "no-match", ErrNoAncestor: "no-match", ErrStateAbsent: "no-match",
		ErrStateAmbiguous: "unclassifiable", ErrUsage: "", ErrBadPattern: "", ErrStateUsage: "", kitErr: "", nil: "",
	} {
		code, ok := InputReason(err)
		if code.Text() != want || ok != (want != "") {
			t.Errorf("InputReason(%v) = %q %v, want %q", err, code.Text(), ok, want)
		}
		if ok && code.Class() != reasons.ClassInput {
			t.Errorf("%v maps to a non-input code %q", err, code.Text())
		}
	}
}
