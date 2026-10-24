//go:build !unix

package proc

import "errors"

// ErrUnsupported is returned by Run off unix: without process groups a
// timeout could not stop the program's descendants.
var ErrUnsupported = errors.New("proc: bounded runs are unsupported on this platform")

// Run fails off unix.
func Run(spec Spec) (Result, error) {
	if err := spec.validate(); err != nil {
		return Result{}, err
	}
	return Result{}, ErrUnsupported
}
