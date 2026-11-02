package native

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// probeTimeout bounds the two short sandbox probes (`/bin/true` and the `-v` version).
const probeTimeout = 5 * time.Second

// maxProbeOutput bounds what a probe may print.
const maxProbeOutput = 1 << 20

// seconds converts a cap in seconds to a Duration without overflowing.
func seconds(n int) time.Duration {
	const limit = 1 << 30
	if n > limit {
		n = limit
	}
	return time.Duration(n) * time.Second
}

// runSpec builds the proc spec for one sandboxed command.
func (j *job) runSpec(argv []string, env []envVar, timeout time.Duration, maxBytes int) proc.Spec {
	return proc.Spec{Argv: argv, Dir: j.stage, Env: envList(env), Timeout: timeout, MaxBytes: maxBytes, Now: j.s.Clock}
}

// startError renders a program that could not start the way Python's OSError reads.
func startError(err error) error {
	var spawn *proc.SpawnError
	if errors.As(err, &spawn) {
		return osError(spawn.Err, spawn.Path)
	}
	return err
}

// probe runs a short command (the isolation probe, the version query) and returns its result.
func (j *job) probe(argv []string, env []envVar) (proc.Result, error) {
	res, err := j.d.run(j.runSpec(argv, env, probeTimeout, maxProbeOutput))
	if err != nil {
		return res, startError(err)
	}
	return res, nil
}

// bounded runs the analyzer with the wall-clock and joint output caps and returns what it printed (cut to the
// cap when a bound stopped it), the run record and the typed errors.
//
// run_bounded stops on `sum(sizes) > max_bytes`, core/proc on `>= MaxBytes`: asking proc for max+1 makes a
// program that prints exactly max bytes a clean run, as it always was.
func (j *job) bounded(argv []string, env []envVar) (stdout, stderr []byte, run map[string]any, errs []string, err error) {
	budget := j.cfg.maxBytes
	res, err := j.d.run(j.runSpec(argv, env, seconds(j.cfg.timeout), min(budget, math.MaxInt-1)+1))
	if err != nil {
		return nil, nil, nil, nil, startError(err)
	}
	stdout, stderr = res.Stdout, res.Stderr
	if res.Reason != "" {
		stdout, stderr = trimToBudget(stdout, stderr, budget)
	}
	return stdout, stderr, runRecord(res), res.Errors(), nil
}

// trimToBudget cuts both streams jointly to budget bytes: stdout keeps its bytes first, stderr gets the rest.
func trimToBudget(stdout, stderr []byte, budget int) ([]byte, []byte) {
	out := stdout[:min(len(stdout), budget)]
	return out, stderr[:min(len(stderr), budget-len(out))]
}

// runRecord is the run dict of the manifest spec: wall-clock stamps, duration and how the process ended (an
// exit code, or the signal that killed it).
func runRecord(res proc.Result) map[string]any {
	m := map[string]any{
		"started_at": isoZ(res.Started), "ended_at": isoZ(res.Ended), "duration_ms": res.Duration.Milliseconds(),
		"exit_code": nil, "signal": nil,
	}
	if res.ReturnCode >= 0 {
		m["exit_code"] = res.ReturnCode
	} else {
		m["signal"] = -res.ReturnCode
	}
	return m
}

// isoZ is datetime.isoformat() of a UTC time with "Z" for "+00:00": microseconds appear only when non-zero.
func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05Z")
	}
	return fmt.Sprintf("%s.%06dZ", t.Format("2006-01-02T15:04:05"), t.Nanosecond()/1000)
}

// firstLine is str.splitlines()[0]: the text before the first Python line boundary ("" for an empty text).
func firstLine(s string) string {
	if i := strings.IndexAny(s, "\n\r\v\f\x1c\x1d\x1e\u0085  "); i >= 0 {
		return s[:i]
	}
	return s
}
