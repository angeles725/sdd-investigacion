package cishard

import (
	"fmt"
	"sort"
	"strings"
)

// manifestOut is one manifest and what the writer has to say about it.
type manifestOut struct {
	text     string   // the manifest, header first
	findings []string // typed findings "<kind>: <detail>": any of them makes the command exit 1
	raised   []string // the finding kinds that raised the header exit from 0 to 1 (none when it was not raised)
}

// rowFor maps a package's final package-level action to its manifest row. A planned package with no final event is
// FAIL: a run that never reported cannot be a pass.
func rowFor(final string) string {
	switch final {
	case "pass":
		return "PASS"
	case "skip":
		return "SKIP"
	}
	return "FAIL"
}

// buildManifest writes `# shard I/N suites=K exit=RC` and one `<package> <PASS|FAIL|SKIP>` row per planned package, in
// the planned order, then compares the rows with the stream and the exit code. rc is the status of `make` itself. The
// manifest must fail the join on its own, even if a workflow step swallowed the command's exit code: so with ANY finding
// and rc 0 the header is written exit=1 (a non-zero rc is written as given, never overwritten).
func buildManifest(spec shardSpec, rc int, planned []string, st streamInfo) manifestOut {
	var out manifestOut
	rows := make([]string, 0, len(planned))
	var failed, nofinal []string
	passes, skips := 0, 0
	for _, p := range planned {
		final, ok := st.final[p]
		row := rowFor(final)
		if !ok && st.events > 0 {
			nofinal = append(nofinal, p)
		}
		switch row {
		case "FAIL":
			failed = append(failed, p)
		case "PASS":
			passes++
		case "SKIP":
			skips++
		}
		rows = append(rows, p+" "+row)
	}
	out.findings = streamFindings(planned, st)
	for _, p := range nofinal {
		out.findings = append(out.findings, fmt.Sprintf("no-final-event: %s has no final package-level event; recorded FAIL", p))
	}
	out.findings = append(out.findings, exitDisagreement(rc, failed, passes, skips)...)
	if rc == 0 && len(out.findings) > 0 {
		rc = 1
		out.raised = findingKinds(out.findings)
	}
	out.text = fmt.Sprintf("# shard %d/%d suites=%d exit=%d\n%s\n", spec.i, spec.n, len(planned), rc, strings.Join(rows, "\n"))
	return out
}

// findingKinds returns the distinct kinds (the text before the first colon) of the findings, in order.
func findingKinds(findings []string) []string {
	var kinds []string
	seen := map[string]bool{}
	for _, f := range findings {
		kind, _, _ := strings.Cut(f, ":")
		if !seen[kind] {
			seen[kind] = true
			kinds = append(kinds, kind)
		}
	}
	return kinds
}

// streamFindings are the findings about the stream alone: it holds no event, lines were unreadable, or it names a
// package that was not planned.
func streamFindings(planned []string, st streamInfo) []string {
	var f []string
	if st.events == 0 {
		if st.blank {
			f = append(f, "empty-input: the go test -json stream has no bytes; every planned package is recorded FAIL and exit is forced non-zero")
		} else {
			f = append(f, fmt.Sprintf("no-events: the go test -json stream holds no readable event (%d malformed line(s)); every planned package is recorded FAIL and exit is forced non-zero", st.malformed))
		}
	}
	if st.malformed > 0 && st.events > 0 {
		f = append(f, fmt.Sprintf("malformed-lines: %d line(s) of the stream are not JSON events", st.malformed))
	}
	isPlanned := make(map[string]bool, len(planned))
	for _, p := range planned {
		isPlanned[p] = true
	}
	var extra []string
	for p := range st.seen {
		if !isPlanned[p] {
			extra = append(extra, p)
		}
	}
	sort.Strings(extra)
	for _, p := range extra {
		f = append(f, fmt.Sprintf("unplanned-package: %s is in the stream but not in the plan", p))
	}
	return f
}

// exitDisagreement compares the exit given with the rows: exit 0 with a FAIL row, or a non-zero exit that no row
// explains (no row is FAIL, whatever mix of PASS and SKIP rows there is).
func exitDisagreement(rc int, failed []string, passes, skips int) []string {
	if rc == 0 && len(failed) > 0 {
		return []string{fmt.Sprintf("exit-0-with-fail: --exit 0 but %d row(s) are FAIL — [%s]", len(failed), strings.Join(failed, ", "))}
	}
	if rc != 0 && len(failed) == 0 {
		return []string{fmt.Sprintf("exit-nonzero-no-fail: --exit %d but no row is FAIL (%d PASS, %d SKIP)", rc, passes, skips)}
	}
	return nil
}
