package ciworkflow

import "strings"

// Job is one entry of the `jobs:` map of a workflow, as far as the guard tests need it.
type Job struct {
	ID     string   // the key under `jobs:`
	Name   string   // the value of the job's own `name:` line, unquoted; "" when the job has none
	Needs  []string // `needs:` as a scalar, a flow list or a block list; nil when the job has none
	If     string   // the text after the job-level `if:`; "" when the job has none (a step's `if:` is not read)
	Matrix bool     // the job has `strategy:` with a `matrix:` key
	Body   []string // the significant lines nested under the job (comments dropped), for step-level checks
}

// Jobs returns the jobs of the workflow source src in file order. Like EventPaths it is not a YAML parser: it
// reads the block form the kit's workflows use and answers Unrecognised, never an empty list, for no block-form
// `jobs:` (missing, or a flow mapping), a flow-form job (`build: {runs-on: x}`), zero jobs, or a `needs:` value it
// cannot read.
func Jobs(src string) ([]Job, State) {
	jobs, ok := child(significant(strings.Split(src, "\n")), "jobs")
	if !ok || jobs.inline != "" || len(jobs.body) == 0 {
		return nil, Unrecognised
	}
	top := indent(jobs.body[0])
	var out []Job
	for _, l := range jobs.body {
		if indent(l) > top { // never the first line: top is its indent, so a job is already open
			out[len(out)-1].Body = append(out[len(out)-1].Body, l)
			continue
		}
		id, rest, ok := strings.Cut(strings.TrimSpace(l), ":")
		if !ok || strings.TrimSpace(rest) != "" || strings.HasPrefix(id, "- ") {
			return nil, Unrecognised // a flow-form job, a list item or a line that is not `id:`
		}
		out = append(out, Job{ID: unquote(id)})
	}
	for i := range out {
		if !fillJob(&out[i]) {
			return nil, Unrecognised
		}
	}
	return out, Found
}

// fillJob reads the keys of j.Body into the other fields; false when `needs:` cannot be read.
func fillJob(j *Job) bool {
	if n, ok := child(j.Body, "name"); ok {
		j.Name = unquote(n.inline)
	}
	if n, ok := child(j.Body, "if"); ok {
		j.If = n.inline
	}
	if s, ok := child(j.Body, "strategy"); ok {
		_, j.Matrix = child(s.body, "matrix")
	}
	n, ok := child(j.Body, "needs")
	if !ok {
		return true
	}
	needs, good := needsList(n)
	j.Needs = needs
	return good
}

func needsList(n node) ([]string, bool) {
	if n.inline == "[]" {
		return nil, true
	}
	if strings.HasPrefix(n.inline, "[") {
		list, st := flowList(n.inline)
		return list, st == Found
	}
	if n.inline != "" {
		return []string{unquote(n.inline)}, true
	}
	var out []string
	for _, l := range n.body {
		item, ok := strings.CutPrefix(strings.TrimSpace(l), "- ")
		if !ok {
			return nil, false
		}
		out = append(out, unquote(item))
	}
	return out, len(out) > 0
}
