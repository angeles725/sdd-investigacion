package flakehunt

import (
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// tools are the resolved paths of the programs a hunt starts.
type tools struct{ timeout, bash, node string }

// hunt is one run of the command after its inputs were validated and its output directory created.
type hunt struct {
	s       cli.Stdio
	c       config
	repo    string
	out     string
	results string
	env     []string // the caller's environment, as every child sees it before the per-suite additions
	suites  []string
	tools   tools
	loads   *pool
	intr    *interrupter

	fails, skips map[string]int    // per suite: failed runs, skipped runs
	first        map[string]string // per suite: its first failing line
}

// outcome is how the measuring loop ended.
type outcome struct {
	expired     int // the run in which the load was found gone (0: never)
	interrupted int // the exit code of a signal received (0: none)
}

// measure runs every suite once per run, in list order, under the load. A suite never starts without its load: a
// worker found dead before one is `expired`, since a suite measured without load would read as stable.
func (h *hunt) measure() (out outcome, err error) {
	rf, err := os.OpenFile(h.results, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		return out, err
	}
	defer rf.Close()
	h.fails, h.skips, h.first = map[string]int{}, map[string]int{}, map[string]string{}
	for run := 1; run <= h.c.runs; run++ {
		for i, s := range h.suites {
			if code := h.intr.pending(); code != 0 {
				out.interrupted = code
				return out, nil
			}
			if !h.loads.alive() {
				out.expired = run
				return out, nil
			}
			idx := i + 1
			rc, sig := h.runSuite(run, idx, s)
			if sig != 0 {
				out.interrupted = sig
				return out, nil
			}
			status, first := h.record(run, idx, s, rc)
			if _, err := fmt.Fprintf(rf, "%d\t%s\t%s\t%s\n", run, s, status, first); err != nil {
				return out, err
			}
		}
	}
	return out, nil
}

// record judges one finished suite from its log and keeps the tallies.
func (h *hunt) record(run, idx int, s string, rc int) (status, first string) {
	log := h.logPath(run, idx)
	text, _ := os.ReadFile(log)
	status, first = verdict(rc, string(text), log)
	switch status {
	case stFail, stTimeout:
		h.fails[s]++
		if h.first[s] == "" {
			h.first[s] = first
		}
	case stSkip:
		h.skips[s]++
	}
	return status, first
}
