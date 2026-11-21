package ciworkflow

import (
	"reflect"
	"strings"
	"testing"
)

const jobsSrc = `name: x
on:
  push:
jobs:
  first:
    # a comment
    runs-on: ubuntu
    needs: a
    steps:
      - name: not the job name
        if: always()
  second:
    name: "Second name"
    needs: [a, 'b']
    if: always()
    strategy:
      fail-fast: false
      matrix:
        shard: [1, 2]
    steps:
      - run: x
  third:
    needs:
      - a
      - b
    strategy:
      fail-fast: false
    steps:
      - run: y
  last:
    runs-on: ubuntu
`

func TestJobs(t *testing.T) {
	jobs, st := Jobs(jobsSrc)
	if st != Found || len(jobs) != 4 {
		t.Fatalf("got %d jobs, state %v; want 4, found", len(jobs), st)
	}
	type view struct {
		ID, Name, If string
		Needs        []string
		Matrix       bool
	}
	want := []view{
		{"first", "", "", []string{"a"}, false},
		{"second", "Second name", "always()", []string{"a", "b"}, true},
		{"third", "", "", []string{"a", "b"}, false},
		{"last", "", "", nil, false},
	}
	for i, w := range want {
		g := jobs[i]
		if got := (view{g.ID, g.Name, g.If, g.Needs, g.Matrix}); !reflect.DeepEqual(got, w) {
			t.Errorf("job %d: got %+v, want %+v", i, got, w)
		}
	}
	if len(jobs[0].Body) == 0 || !strings.Contains(strings.Join(jobs[0].Body, "\n"), "if: always()") {
		t.Errorf("the body of the first job lost its step lines: %q", jobs[0].Body)
	}
	if strings.Contains(strings.Join(jobs[0].Body, "\n"), "second") {
		t.Errorf("the body of the first job leaked the next job: %q", jobs[0].Body)
	}
}

func TestJobsEdges(t *testing.T) {
	cases := []struct {
		name, src string
		ids       []string
		state     State
	}{
		{"single job", "jobs:\n  only:\n    runs-on: x\n", []string{"only"}, Found},
		{"last line without newline", "jobs:\n  a:\n    runs-on: x\n  b:\n    runs-on: y", []string{"a", "b"}, Found},
		{"job with no body", "jobs:\n  a:\n  b:\n    runs-on: y\n", []string{"a", "b"}, Found},
		{"jobs followed by another top-level key", "jobs:\n  a:\n    runs-on: x\nenv:\n  K: v\n", []string{"a"}, Found},
		{"quoted id", "jobs:\n  'a':\n    runs-on: x\n", []string{"a"}, Found},
		{"no jobs key", "name: x\non:\n  push:\n", nil, Unrecognised},
		{"flow-form jobs", "jobs: {a: {runs-on: x}}\n", nil, Unrecognised},
		{"empty jobs", "jobs:\nenv:\n  K: v\n", nil, Unrecognised},
		{"flow-form job", "jobs:\n  a: {runs-on: x}\n  b:\n    runs-on: y\n", nil, Unrecognised},
		{"flow-form job in last position", "jobs:\n  a:\n    runs-on: x\n  b: {runs-on: y}\n", nil, Unrecognised},
		{"inline value with an indented body", "jobs: x\n  a:\n    runs-on: u\n", nil, Unrecognised},
		{"list item with a key under jobs", "jobs:\n  - a:\n    runs-on: u\n", nil, Unrecognised},
		{"list under jobs", "jobs:\n  - a\n", nil, Unrecognised},
		{"unreadable needs", "jobs:\n  a:\n    needs: [x\n", nil, Unrecognised},
		{"needs with no value", "jobs:\n  a:\n    needs:\n    runs-on: x\n", nil, Unrecognised},
		{"needs mapping", "jobs:\n  a:\n    needs:\n      k: v\n", nil, Unrecognised},
		{"indented jobs is not the top-level key", "x:\n  jobs:\n    a:\n      runs-on: x\n", nil, Unrecognised},
	}
	for _, c := range cases {
		jobs, st := Jobs(c.src)
		var ids []string
		for _, j := range jobs {
			ids = append(ids, j.ID)
		}
		if st != c.state || !reflect.DeepEqual(ids, c.ids) {
			t.Errorf("%s: got %v / %v, want %v / %v", c.name, ids, st, c.ids, c.state)
		}
	}
}

func TestJobsNeedsForms(t *testing.T) {
	for _, c := range []struct {
		needs string
		want  []string
	}{
		{"needs: a", []string{"a"}},
		{`needs: "a"`, []string{"a"}},
		{"needs: [a]", []string{"a"}},
		{"needs: [ a , b ]", []string{"a", "b"}},
		{"needs: []", nil},
		{"needs:\n      - a\n      - b", []string{"a", "b"}},
	} {
		jobs, st := Jobs("jobs:\n  j:\n    " + c.needs + "\n")
		if st != Found || len(jobs) != 1 || !reflect.DeepEqual(jobs[0].Needs, c.want) {
			t.Errorf("%q: got %+v / %v, want needs %v", c.needs, jobs, st, c.want)
		}
	}
}

// A step-level or nested key must never be read as the job's own.
func TestJobsOnlyReadsJobLevelKeys(t *testing.T) {
	jobs, st := Jobs("jobs:\n  j:\n    steps:\n      - name: n\n        if: always()\n        needs: x\n    env:\n      name: v\n")
	if st != Found || len(jobs) != 1 {
		t.Fatalf("got %+v / %v", jobs, st)
	}
	if j := jobs[0]; j.Name != "" || j.If != "" || j.Needs != nil || j.Matrix {
		t.Errorf("a nested key leaked into the job: %+v", j)
	}
}
