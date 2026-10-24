package parity

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
)

// Named normalisers an intended.json entry may declare. They run on stdout,
// stderr and the effect of BOTH sides before comparison; exit is never touched.
const (
	NormTime     = "time"     // ISO-8601 / RFC 3339 timestamps -> <TIME>
	NormTempRoot = "temproot" // the sandbox path -> <TMP>
	NormPID      = "pid"      // a declared regex -> <PID>
)

var timeRe = regexp.MustCompile(`\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?`)

// normaliserEntry is a {"normalise": ..., "reason": ...} intended.json entry.
type normaliserEntry struct{ Name, Pattern, Reason string }

// Normaliser is a validated, compiled normaliser declaration.
type Normaliser struct {
	Name   string
	Reason string
	re     *regexp.Regexp // nil for temproot
	repl   string
}

func compileNormalisers(entries []normaliserEntry) ([]Normaliser, []Problem) {
	var out []Normaliser
	var probs []Problem
	bad := func(kind, format string, a ...any) {
		probs = append(probs, Problem{kind, fmt.Sprintf(format, a...)})
	}
	for _, e := range entries {
		ok := true
		if strings.TrimSpace(e.Reason) == "" {
			bad(KindNoReason, "intended.json normaliser %q: every normaliser needs a non-empty reason", e.Name)
			ok = false
		}
		n := Normaliser{Name: e.Name, Reason: e.Reason}
		switch e.Name {
		case NormTime:
			n.re, n.repl = timeRe, "<TIME>"
		case NormTempRoot:
			n.repl = "<TMP>"
		case NormPID:
			n.repl = "<PID>"
			if e.Pattern == "" {
				bad(KindSpecInvalid, "intended.json normaliser %q needs a pattern (the regex that matches the process id)", e.Name)
				ok = false
			} else if re, err := regexp.Compile(e.Pattern); err != nil {
				bad(KindSpecInvalid, "intended.json normaliser %q: bad pattern: %v", e.Name, err)
				ok = false
			} else if re.MatchString("") {
				bad(KindSpecInvalid, "intended.json normaliser %q: the pattern matches the empty string and would rewrite everything", e.Name)
				ok = false
			} else {
				n.re = re
			}
		default:
			bad(KindSpecInvalid, "intended.json: unknown normaliser %q (want time|temproot|pid)", e.Name)
			continue
		}
		if e.Name != NormPID && e.Pattern != "" {
			bad(KindSpecInvalid, "intended.json normaliser %q: pattern is only valid for pid", e.Name)
			ok = false
		}
		if ok {
			out = append(out, n)
		}
	}
	return out, probs
}

// apply rewrites b and reports whether it matched anything.
func (n Normaliser) apply(b []byte, sandbox string) ([]byte, bool) {
	if n.re == nil { // temproot
		if sandbox == "" {
			return b, false
		}
		return bytes.ReplaceAll(b, []byte(sandbox), []byte(n.repl)), bytes.Contains(b, []byte(sandbox))
	}
	return n.re.ReplaceAll(b, []byte(n.repl)), n.re.Match(b)
}

// applyNormalisers normalises the stdout, stderr and effect of both sides, in
// declaration order. A normaliser that rewrote nothing on either side is stale
// and reported as such. The inputs are not modified.
func applyNormalisers(legacy, rsdd Observed, ns []Normaliser, sandbox string) (Observed, Observed, []Problem) {
	var stale []Problem
	for _, n := range ns {
		changed := false
		for _, o := range []*Observed{&legacy, &rsdd} {
			for _, f := range []*[]byte{&o.Stdout, &o.Stderr, &o.Effect} {
				var hit bool
				*f, hit = n.apply(*f, sandbox)
				changed = changed || hit
			}
		}
		if !changed {
			stale = append(stale, Problem{KindStale, fmt.Sprintf("normaliser %q changed nothing on either side: delete the declaration", n.Name)})
		}
	}
	return legacy, rsdd, stale
}
