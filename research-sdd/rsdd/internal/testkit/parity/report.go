package parity

import (
	"fmt"
	"os"
)

// Options selects corpus mode. Corpora are the expanded TARGETS.md tokens.
type Options struct {
	CorpusMode bool
	Corpora    []string
}

// AbsentCorpus is a corpus token that is not an existing directory.
type AbsentCorpus struct{ Path, Why string }

// Counts are the figures of the summary line. Compared counts executed
// (non-skipped) runs.
type Counts struct{ Compared, Equal, Declared, Failed, AbsentCorpora, Skipped int }

// Report is the outcome of RunAll.
type Report struct {
	Results []Result
	Absent  []AbsentCorpus
	Counts  Counts
}

// Summary is the one-line tally.
func (r Report) Summary() string {
	c := r.Counts
	return fmt.Sprintf("parity: compared=%d equal=%d declared-divergent=%d failed=%d absent-corpora=%d skipped=%d",
		c.Compared, c.Equal, c.Declared, c.Failed, c.AbsentCorpora, c.Skipped)
}

// Failed reports whether any run failed.
func (r Report) Failed() bool { return r.Counts.Failed > 0 }

// RunAll runs every case once (plain specs) or once per existing corpus
// (specs with "corpus": true, corpus mode only). Absent corpora are counted
// and listed, never dropped.
func (r *Runner) RunAll(cases []Case, opt Options) Report {
	var rep Report
	add := func(res Result) { rep.Results = append(rep.Results, res) }
	if len(cases) == 0 {
		add(Result{Case: "(specs)", Status: StatusFailed, Problems: []Problem{{KindEmptyInput, "0 parity specs"}}})
	}
	var existing []string
	if opt.CorpusMode {
		for _, tok := range opt.Corpora {
			st, err := os.Stat(tok)
			switch {
			case err != nil:
				rep.Absent = append(rep.Absent, AbsentCorpus{tok, err.Error()})
			case !st.IsDir():
				rep.Absent = append(rep.Absent, AbsentCorpus{tok, "not a directory"})
			default:
				existing = append(existing, tok)
			}
		}
	}
	for _, c := range cases {
		switch {
		case !c.Spec.Corpus:
			add(r.RunCase(c, ""))
		case !opt.CorpusMode:
			add(Result{Case: c.Name, Status: StatusSkipped, Note: "corpus spec, corpus mode is off"})
		case len(existing) == 0:
			add(Result{Case: c.Name, Status: StatusSkipped, Note: "corpus spec, no existing corpus directory"})
		default:
			for _, dir := range existing {
				add(r.RunCase(c, dir))
			}
		}
	}
	if opt.CorpusMode && len(opt.Corpora) == 0 {
		add(Result{Case: "(corpus mode)", Status: StatusFailed, Problems: []Problem{{KindEmptyInput, "0 corpus targets: nothing to read-only compare against"}}})
	}
	rep.Counts.AbsentCorpora = len(rep.Absent)
	for _, res := range rep.Results {
		switch res.Status {
		case StatusEqual:
			rep.Counts.Equal++
		case StatusDeclared:
			rep.Counts.Declared++
		case StatusFailed:
			rep.Counts.Failed++
		case StatusSkipped:
			rep.Counts.Skipped++
		}
	}
	rep.Counts.Compared = rep.Counts.Equal + rep.Counts.Declared + rep.Counts.Failed
	return rep
}
