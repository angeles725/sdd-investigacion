// Package proc is the one home for running a subprocess under bounds and for
// the kill-safety guard: no process group is ever signalled except through
// CheckGroup/SignalGroup, which refuse group ids <= 1, a group that is not
// the child's recorded one, the caller's own group, and a group with no
// member left.
package proc

import "errors"

// ErrGroupGone is what a refusal unwraps to when the group to signal no
// longer has any member: there is nothing left to stop.
var ErrGroupGone = errors.New("process group no longer exists")
