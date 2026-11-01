package adapter

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"

// Error is the port of adapter_core.AdapterError: a fail-closed adapter
// refusal. Msg is the exact Python message. Err, when set, is the typed cause
// (an fsx sentinel for identity failures), reachable through errors.Is.
type Error struct {
	Msg string
	Err error
}

func (e *Error) Error() string { return e.Msg }
func (e *Error) Unwrap() error { return e.Err }

// wrapFsx turns an fsx failure into the AdapterError identity() raises: same
// text, typed cause kept.
func wrapFsx(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := err.(*fsx.Error); ok {
		return &Error{Msg: err.Error(), Err: err}
	}
	return err
}

// Creds are the four process ids refuse_privileged_execution compares. They
// are injected so tests can drive every outcome; CurrentCreds reads the
// process.
type Creds struct{ UID, EUID, GID, EGID int }

// EnvVar is one --setenv pair. The sandbox keeps the caller's order, as the
// Python dict does.
type EnvVar struct{ Key, Value string }

// Host is everything Sandbox reads from the machine, injected: the private
// mount-point directory it creates and checks, the owning uid it requires, the
// working directory relative inputs resolve against, and an existence probe.
type Host struct {
	Root   string // "/tmp/rsdd" on a real host
	UID    int
	Cwd    string            // required only for relative ro_inputs
	Exists func(string) bool // nil means os.Stat(path) succeeds
}
