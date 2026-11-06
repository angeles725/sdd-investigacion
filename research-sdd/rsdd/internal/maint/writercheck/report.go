package writercheck

import (
	"fmt"
	"io"
	"strings"
)

// finding is one thing that fails the check: its type word, what it is about, and the why.
type finding struct{ kind, subject, detail string }

// result is everything a check found.
type result struct {
	suites   []string
	notes    []string
	findings []finding
	full     bool // suite-impact escalated to FULL: the PR also needs the full gate
}

// writeReport is the human form: the required suites, the notes (never fail), the findings and their count.
func writeReport(w io.Writer, r result) {
	fmt.Fprintf(w, "Required suites: %d\n", len(r.suites))
	for _, s := range r.suites {
		fmt.Fprintf(w, "  %s\n", s)
	}
	for _, n := range r.notes {
		fmt.Fprintln(w, n)
	}
	for _, f := range r.findings {
		fmt.Fprintf(w, "%s %s (%s)\n", f.kind, f.subject, f.detail)
	}
	fmt.Fprintf(w, "Findings: %d\n", len(r.findings))
}

// writeJSON is the machine form. It is written by hand because the escaping is part of the contract: a backslash and
// a quote are escaped, a tab becomes a space, everything else is verbatim (encoding/json would also escape < > & and
// control characters).
func writeJSON(w io.Writer, r result) {
	status := "ok"
	if len(r.findings) > 0 {
		status = "findings"
	}
	var b strings.Builder
	fmt.Fprintf(&b, `{"status":"%s","full_gate_needed":%t,"required":[`, status, r.full)
	for i, s := range r.suites {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, `"%s"`, jsonEscape(s))
	}
	b.WriteString(`],"findings":[`)
	for i, f := range r.findings {
		if i > 0 {
			b.WriteByte(',')
		}
		fmt.Fprintf(&b, `{"type":"%s","subject":"%s","detail":"%s"}`, jsonEscape(f.kind), jsonEscape(f.subject), jsonEscape(f.detail))
	}
	b.WriteString("]}\n")
	io.WriteString(w, b.String())
}

var jsonEscaper = strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\t", " ")

func jsonEscape(s string) string { return jsonEscaper.Replace(s) }
