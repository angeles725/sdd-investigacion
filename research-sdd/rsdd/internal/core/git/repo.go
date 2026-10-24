package git

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// ErrUnexpectedOutput is git output a question cannot read (rev-list --count printing a non-count).
var ErrUnexpectedOutput = errors.New("git: unexpected output")

// Remotes is `git remote`, read as `mapfile -t` does: one name per line, in git's order, nil for none.
func (r Runner) Remotes(dir string) ([]string, error) {
	out, err := r.Run(dir, "remote")
	if err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, nil
	}
	return strings.Split(strings.TrimSuffix(string(out), "\n"), "\n"), nil
}

// RemoteURL is `git remote get-url <name>` as `$(...)` reads it (trailing newlines cut).
func (r Runner) RemoteURL(dir, name string) (string, error) {
	out, err := r.Run(dir, "remote", "get-url", name)
	if err != nil {
		return "", err
	}
	return trimNL(out), nil
}

// ResolveCommit is `git rev-parse --verify --quiet <rev>^{commit}`: the full sha and true, or false when rev
// names no commit here (exit 1).
func (r Runner) ResolveCommit(dir, rev string) (string, bool, error) {
	return r.answer(dir, "rev-parse", "--verify", "--quiet", rev+"^{commit}")
}

// MergeBase is `git merge-base <a> <b>`: the best common ancestor and true, or false when there is none (exit 1).
func (r Runner) MergeBase(dir, a, b string) (string, bool, error) {
	return r.answer(dir, "merge-base", a, b)
}

// IsAncestor is `git merge-base --is-ancestor <a> <b>`: whether a is an ancestor of (or equal to) b.
func (r Runner) IsAncestor(dir, a, b string) (bool, error) {
	_, ok, err := r.answer(dir, "merge-base", "--is-ancestor", a, b)
	return ok, err
}

// CountRange is `git rev-list --count <rng>`; anything but a plain count is ErrUnexpectedOutput.
func (r Runner) CountRange(dir, rng string) (int, error) {
	out, err := r.Run(dir, "rev-list", "--count", rng)
	if err != nil {
		return 0, err
	}
	s := trimNL(out)
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, fmt.Errorf("%w: rev-list --count %s printed %q", ErrUnexpectedOutput, rng, s)
	}
	return strconv.Atoi(s)
}

// answer runs a yes/no question whose "no" is exit 1: the trimmed stdout and true, "" and false for exit 1,
// or the error of a run that could not answer.
func (r Runner) answer(dir string, args ...string) (string, bool, error) {
	out, err := r.Run(dir, args...)
	var ee *ExitError
	switch {
	case errors.As(err, &ee) && ee.Code == 1:
		return "", false, nil
	case err != nil:
		return "", false, err
	}
	return trimNL(out), true, nil
}

// trimNL is what `$(...)` leaves of b: the trailing newlines cut.
func trimNL(b []byte) string { return strings.TrimRight(string(b), "\n") }
