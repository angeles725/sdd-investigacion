package scoreloop

import (
	"os"
	"sort"
)

// Facts is everything the criteria need from the transcript.
type Facts struct {
	// Given is true when --transcript was passed.
	Given bool
	// MissingTool names a tool the parse needs and the PATH lacks (only jq, and only with a jq override).
	MissingTool string
	// ParseFailed: the transcript did not parse cleanly (unreadable, invalid JSON, or an unexpected record shape).
	ParseFailed bool
	// AnyOrigin: some record carries a non-null .origin (the marker of a Claude-Code-shaped transcript).
	AnyOrigin bool

	OperatorEpochs []int64 // genuine human turns, in time order
	FinalEpochs    []int64 // the last assistant record before each operator turn (and at the end)
	FinalParas     []string

	HasCompaction   bool
	FirstCompaction int64

	HasSpan               bool
	FirstEpoch, LastEpoch int64
	FirstISO, LastISO     string
}

// usable reports whether the transcript parsed, so the criteria can read it.
func (f *Facts) usable() bool { return f.Given && f.MissingTool == "" && !f.ParseFailed }

// unrecognized is the round-3 guard: a transcript that cannot be interpreted (no record carries .origin, or it has
// neither an operator turn nor an assistant record) scores degraded, never a clean wrong pass.
func (f *Facts) unrecognized() bool {
	if !f.usable() {
		return false
	}
	return !f.AnyOrigin || (len(f.OperatorEpochs) == 0 && len(f.FinalParas) == 0)
}

func sortRows(rows []row) {
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].when.Before(rows[j].when) })
}

// loadTranscript reads path into Facts. run evaluates a jq override (nil when the built-in filters apply).
func loadTranscript(path string, cfg *Config, run jqRunner) *Facts {
	f := &Facts{Given: true, AnyOrigin: true}
	var override map[int]verdict
	if cfg.OperatorJQ != "" || cfg.CompactJQ != "" {
		var err error
		if override, err = run(path, cfg); err != nil {
			f.setJQFailure(err)
			return f
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		f.ParseFailed = true
		return f
	}
	vals, err := decodeValues(data)
	if err != nil {
		f.ParseFailed = true
		return f
	}
	rows, err := buildRows(vals, override)
	if err != nil {
		f.ParseFailed = true
		return f
	}
	f.AnyOrigin = anyOrigin(vals)
	f.fold(rows)
	return f
}

// fold walks the time-ordered rows: the span, the first compaction, the operator turns, and the final assistant
// message of every stretch between operator turns.
func (f *Facts) fold(rows []row) {
	var pending *row
	flush := func() {
		if pending != nil {
			f.FinalEpochs = append(f.FinalEpochs, pending.when.Unix())
			f.FinalParas = append(f.FinalParas, pending.para)
			pending = nil
		}
	}
	for i := range rows {
		r := &rows[i]
		epoch := r.when.Unix()
		if !f.HasSpan {
			f.HasSpan, f.FirstEpoch, f.FirstISO = true, epoch, r.ts
		}
		f.LastEpoch, f.LastISO = epoch, r.ts
		if !f.HasCompaction && r.compact {
			f.HasCompaction, f.FirstCompaction = true, epoch
		}
		if r.operator {
			f.OperatorEpochs = append(f.OperatorEpochs, epoch)
			flush()
			continue
		}
		if r.typ == "assistant" {
			pending = r
		}
	}
	flush()
}
