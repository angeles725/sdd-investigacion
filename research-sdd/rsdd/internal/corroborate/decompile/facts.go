package decompile

import (
	"bytes"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	factsDefaultBudget = 30 // seconds: also the cap of the derived budget
	factsBudgetDivisor = 8
)

// factsBudgetRe is a valid RSDD_CLASSFACTS_TIMEOUT: 1-99999 seconds, ASCII digits only.
var factsBudgetRe = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)

// factsResult is what the class-file facts step produced: its first stdout line, the first line of its stderr, its
// status, and whether its budget ran out first.
type factsResult struct {
	line, firstErr string
	rc             int
	timedOut       bool
}

// newFactsRunner reads the class-file facts in process under a budget. The run is a goroutine that cannot be
// stopped: past the budget it is abandoned (its result is never read) and the decompilation goes on. A panic in it
// is the status 1 the rsdd panic boundary would have given a child process.
func newFactsRunner(run func([]string, cli.Stdio) int, after func(time.Duration) <-chan time.Time) func(string, time.Duration, cli.Stdio) factsResult {
	return func(in string, budget time.Duration, s cli.Stdio) factsResult {
		var out, errb bytes.Buffer
		var rc int
		done := make(chan struct{}) // closed, never sent on: an abandoned run cannot block on it
		go func() {
			defer close(done)
			defer func() {
				if recover() != nil {
					errb.WriteString("rsdd: internal-error")
					rc = 1
				}
			}()
			rc = run([]string{in}, cli.Stdio{Out: &out, Err: &errb, Env: s.Env, Environ: s.Environ, Clock: s.Clock, Cwd: s.Cwd})
		}()
		select {
		case <-done: // rc, out and errb are only read after the close, so the abandoned case never races
			first, _, _ := strings.Cut(errb.String(), "\n")
			return factsResult{line: strings.TrimRight(out.String(), "\n"), firstErr: first, rc: rc}
		case <-after(budget):
			return factsResult{timedOut: true}
		}
	}
}

// factsBudget is the helper's OWN small budget, not a second full engine timeout: RSDD_CLASSFACTS_TIMEOUT, else
// min(30, timeout/8) seconds (at least 1; 30 when the engines are unbounded). An invalid override warns.
func (j *job) factsBudget() time.Duration {
	raw := j.s.Env("RSDD_CLASSFACTS_TIMEOUT")
	if factsBudgetRe.MatchString(raw) {
		secs, _ := strconv.Atoi(raw) // the pattern allows at most 5 digits
		return time.Duration(secs) * time.Second
	}
	if raw != "" {
		fmt.Fprintf(j.s.Err, "WARN: invalid RSDD_CLASSFACTS_TIMEOUT=%s (positive seconds); using the derived default\n", raw)
	}
	secs := factsDefaultBudget
	if j.cfg.timeout > 0 {
		secs = min(max(j.cfg.timeout/factsBudgetDivisor, 1), factsDefaultBudget)
	}
	return time.Duration(secs) * time.Second
}

// classfileHeader prints, BEFORE any engine runs, the one CLASSFILE line read straight from the class-file bytes. It
// goes to STDERR so the typed result stays the first stdout line. Failures keep the SAME field set (all unknown)
// with a typed reason: facts-unbounded (no timeout binary; the step is skipped), facts-timeout (the budget ran
// out), facts-error rc=N (the step failed; its first stderr line follows as a WARN).
func (j *job) classfileHeader() {
	if !j.haveTimeout {
		fmt.Fprintln(j.s.Err, classfileUnknown+" reason=facts-unbounded")
		return
	}
	r := j.d.facts(j.path(j.cfg.in), j.factsBudget(), j.s)
	switch {
	case r.timedOut:
		fmt.Fprintln(j.s.Err, classfileUnknown+" reason=facts-timeout")
	case r.rc == 0 && r.line != "":
		fmt.Fprintln(j.s.Err, r.line)
	default:
		fmt.Fprintf(j.s.Err, "%s reason=facts-error rc=%d\n", classfileUnknown, r.rc)
		if r.firstErr != "" {
			fmt.Fprintln(j.s.Err, "WARN: classfile-facts helper: "+r.firstErr)
		}
	}
}
