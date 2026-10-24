package gh

import (
	"bytes"
	"strings"
)

// Visibility is one probe: State, RC (the shell exit code), Why (gh's first stderr line), Raw (its stdout,
// trailing newlines cut and ASCII upper-cased, for UNRECOGNISED reporting) and the Bound applied.
type Visibility struct {
	State State
	RC    int
	Why   string
	Raw   string
	Bound Bound
}

// Probe is gh_visibility_probe: `gh repo view <repo> --json visibility --jq .visibility` in o.Dir under the
// bound. Only a decided State (PUBLIC, PRIVATE, INTERNAL) is an answer; callers must treat every other State
// as unknown. Unlike Run, a SIGKILLed gh is GH_ERROR 137, as in the bash. The error is non-nil only for
// StateProbeFailed.
func Probe(o Options, repo string) (Visibility, error) {
	out, err := o.launch([]string{"repo", "view", repo, "--json", "visibility", "--jq", ".visibility"})
	v := Visibility{State: out.state, RC: out.rc, Why: firstLine(out.res.Stderr), Raw: commandSubst(out.res.Stdout), Bound: out.bound}
	if v.State == "" {
		v.State = StateUnrecognised
		if s := State(v.Raw); s.Decided() {
			v.State = s
		}
	}
	return v, err
}

// commandSubst is what `$(...) | tr '[:lower:]' '[:upper:]'` leaves of b: NUL bytes dropped, trailing
// newlines cut, ASCII letters upper-cased (tr is byte-wise).
func commandSubst(b []byte) string {
	b = bytes.TrimRight(bytes.ReplaceAll(b, []byte{0}, nil), "\n")
	up := make([]byte, len(b))
	for i, c := range b {
		if 'a' <= c && c <= 'z' {
			c -= 'a' - 'A'
		}
		up[i] = c
	}
	return string(up)
}

// firstLine is `sed -n 1p`: b up to its first newline.
func firstLine(b []byte) string {
	s, _, _ := strings.Cut(string(b), "\n")
	return s
}
