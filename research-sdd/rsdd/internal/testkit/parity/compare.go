package parity

import (
	"bytes"
	"fmt"
	"strings"
)

// Observed is what one side produced.
type Observed struct {
	Stdout []byte
	Stderr []byte
	Exit   int
}

// Status is the verdict for one compared run.
type Status string

const (
	StatusEqual    Status = "equal"
	StatusDeclared Status = "declared-divergent"
	StatusFailed   Status = "failed"
	StatusSkipped  Status = "skipped"
)

const excerptRadius = 24

// Diverging returns, per field, a bounded description of how legacy and rsdd
// differ. A field that matches is absent from the map.
func Diverging(legacy, rsdd Observed) map[string]string {
	out := map[string]string{}
	if d := diffBytes("stdout", legacy.Stdout, rsdd.Stdout); d != "" {
		out["stdout"] = d
	}
	if d := diffBytes("stderr", legacy.Stderr, rsdd.Stderr); d != "" {
		out["stderr"] = d
	}
	if legacy.Exit != rsdd.Exit {
		out["exit"] = fmt.Sprintf("exit differs: legacy %d, rsdd %d", legacy.Exit, rsdd.Exit)
	}
	return out
}

// Judge turns the observed divergences and the declared ones into a status
// and typed problems.
func Judge(legacy, rsdd Observed, declared []Intended) (Status, []Problem) {
	diff := Diverging(legacy, rsdd)
	decl := map[string]bool{}
	for _, d := range declared {
		decl[d.Field] = true
	}
	var probs []Problem
	for _, f := range []string{"stdout", "stderr", "exit"} {
		d, diverges := diff[f]
		switch {
		case diverges && !decl[f]:
			probs = append(probs, Problem{KindUndeclared, d})
		case !diverges && decl[f]:
			probs = append(probs, Problem{KindStale, fmt.Sprintf("%s is declared in intended.json but no longer diverges: delete the declaration", f)})
		}
	}
	switch {
	case len(probs) > 0:
		return StatusFailed, probs
	case len(diff) > 0:
		return StatusDeclared, nil
	}
	return StatusEqual, nil
}

// diffBytes names the stream and the first differing byte offset and line,
// with a bounded excerpt of both sides. Equal input yields "".
func diffBytes(stream string, a, b []byte) string {
	if bytes.Equal(a, b) {
		return ""
	}
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] {
		i++
	}
	line := 1 + bytes.Count(a[:i], []byte("\n"))
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s differs at byte offset %d (line %d): legacy %d bytes, rsdd %d bytes", stream, i, line, len(a), len(b))
	fmt.Fprintf(&sb, "\n  legacy %s\n  rsdd   %s", excerpt(a, i), excerpt(b, i))
	return sb.String()
}

func excerpt(b []byte, at int) string {
	lo := min(max(at-excerptRadius, 0), len(b))
	hi := min(at+excerptRadius, len(b))
	s := fmt.Sprintf("%q", b[lo:hi])
	if lo > 0 {
		s = "..." + s
	}
	if hi < len(b) {
		s += "..."
	}
	if at >= len(b) {
		s += " (ends before this offset)"
	}
	return s
}
