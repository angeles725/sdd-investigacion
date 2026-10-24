package grammar

import (
	"errors"
	"fmt"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/reasons"
)

func TestInputReason(t *testing.T) {
	for err, want := range map[error]string{
		ErrAbsentInput: "absent-input", ErrUnreadable: "absent-input",
		fmt.Errorf("wrapped: %w", ErrUnreadable): "absent-input", errors.New("other"): "", nil: "",
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
