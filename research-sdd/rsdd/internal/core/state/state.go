// Package state defines the typed input states of the research-sdd toolbelt.
package state

import "fmt"

// State is one of the five envelope states of json-envelope.v1.
type State int

// The five envelope states. The zero value is deliberately invalid.
const (
	Invalid State = iota
	OK
	AbsentInput
	EmptyInput
	NoMatch
	Degraded
)

// String returns the contract spelling of s, or "invalid".
func (s State) String() string {
	if n, ok := stateNames[s]; ok {
		return n
	}
	return "invalid"
}

var stateNames = map[State]string{
	OK:          "ok",
	AbsentInput: "absent-input",
	EmptyInput:  "empty-input",
	NoMatch:     "no-match",
	Degraded:    "degraded",
}

// Parse converts a contract spelling into a State; unknown input is an error.
func Parse(name string) (State, error) {
	for _, s := range All() {
		if stateNames[s] == name {
			return s, nil
		}
	}
	return Invalid, fmt.Errorf("state: unknown state %q", name)
}

// ExitCode returns the --json process exit code for s.
//
// Every valid state exits 0 except Degraded, which exits 3. An invalid State is an error, never a default.
func (s State) ExitCode() (int, error) {
	switch s {
	case OK, AbsentInput, EmptyInput, NoMatch:
		return 0, nil
	case Degraded:
		return 3, nil
	}
	return -1, fmt.Errorf("state: no exit code for invalid state %d", int(s))
}

// All returns the five valid states in contract order.
func All() []State { return []State{OK, AbsentInput, EmptyInput, NoMatch, Degraded} }

// InputClass is one of the typed input tokens of reason-codes.v1.
type InputClass int

// The four input-class tokens. The zero value is deliberately invalid.
const (
	InvalidInput InputClass = iota
	InputAbsent
	InputEmpty
	InputUnclassifiable
	InputNoMatch
)

// String returns the contract spelling of c, or "invalid".
func (c InputClass) String() string {
	if n, ok := inputNames[c]; ok {
		return n
	}
	return "invalid"
}

var inputNames = map[InputClass]string{
	InputAbsent:         "absent-input",
	InputEmpty:          "empty-input",
	InputUnclassifiable: "unclassifiable",
	InputNoMatch:        "no-match",
}

// ParseInputClass converts a contract spelling into an InputClass.
func ParseInputClass(name string) (InputClass, error) {
	for _, c := range AllInputClasses() {
		if inputNames[c] == name {
			return c, nil
		}
	}
	return InvalidInput, fmt.Errorf("state: unknown input class %q", name)
}

// AllInputClasses returns the four valid input classes in contract order.
func AllInputClasses() []InputClass {
	return []InputClass{InputAbsent, InputEmpty, InputUnclassifiable, InputNoMatch}
}
