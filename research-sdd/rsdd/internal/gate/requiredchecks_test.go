package gate

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/ciworkflow"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// requiredCheckFindings judges the workflow sources (file name to text) against the checks the merge gate requires
// by default and returns one finding per problem. A required name must be the check name of a job that:
//   - is not a matrix job (GitHub names those `name (1)`, so the required name would never match);
//   - has a job-level `if:` that is absent or exactly `always()` (any other condition can skip it, and a skipped
//     required check was the hole the `ci_skipped` verdict closes);
//   - sits in a workflow with a `pull_request` event (otherwise it never runs on the pull request being merged).
//
// The check name of a job is its `name:` when it has one, else its id; a name holding `${{` is an expression, not
// a name. No workflow, no job with the name and an unreadable workflow are findings, never a pass.
func requiredCheckFindings(required []string, workflows map[string]string) []string {
	files := make([]string, 0, len(workflows))
	for f := range workflows {
		files = append(files, f)
	}
	sort.Strings(files)
	if len(files) == 0 {
		return []string{"no workflow file was read, so no required check was verified"}
	}
	if len(required) == 0 {
		return []string{"the default required checks list is empty"}
	}
	var out []string
	for _, name := range required {
		found := false
		for _, f := range files {
			jobs, st := ciworkflow.Jobs(workflows[f])
			if st != ciworkflow.Found {
				continue
			}
			for _, j := range jobs {
				if checkName(j) != name {
					continue
				}
				found = true
				out = append(out, jobProblems(name, f, j, workflows[f])...)
			}
		}
		if !found {
			out = append(out, name+": no workflow job produces this check name")
		}
	}
	return out
}

// checkName is the name GitHub reports for the job's check run; "" when it is an expression.
func checkName(j ciworkflow.Job) string {
	n := j.Name
	if n == "" {
		n = j.ID
	}
	if strings.Contains(n, "${{") {
		return ""
	}
	return n
}

func jobProblems(name, file string, j ciworkflow.Job, src string) []string {
	var out []string
	if j.Matrix {
		out = append(out, name+": "+file+" job "+j.ID+" is a matrix job, so its checks are named "+name+" (1), ...")
	}
	if j.If != "" && j.If != "always()" {
		out = append(out, name+": "+file+" job "+j.ID+" has the job-level if: "+j.If+", which can skip it")
	}
	_, st := ciworkflow.EventPaths(src, "pull_request")
	if st == ciworkflow.NoEvent {
		out = append(out, name+": "+file+" has no pull_request event")
	}
	if st == ciworkflow.Unrecognised {
		out = append(out, name+": "+file+" pull_request event is unreadable")
	}
	return out
}

// readWorkflows reads every .yml and .yaml file directly under dir (file name to text).
func readWorkflows(t *testing.T, dir string) map[string]string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("cannot list the workflows, so the required checks were not verified: %v", err)
	}
	wfs := map[string]string{}
	for _, e := range entries {
		if e.IsDir() || (!strings.HasSuffix(e.Name(), ".yml") && !strings.HasSuffix(e.Name(), ".yaml")) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatalf("%s: %v", e.Name(), err)
		}
		wfs[e.Name()] = string(b)
	}
	return wfs
}

func TestDefaultRequiredChecksAreRealJobs(t *testing.T) {
	wfs := readWorkflows(t, filepath.Join(filepath.Dir(kitroot.Dir(t)), ".github", "workflows"))
	for _, f := range requiredCheckFindings(strings.Split(mergeDefaultRequired, ","), wfs) {
		t.Error(f)
	}
}

func TestReadWorkflowsListsOnlyWorkflowFiles(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"a.yml": "A", "b.yaml": "B", "c.txt": "C", "d.yml.bak": "D", "yml": "E"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "sub.yml"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := readWorkflows(t, dir)
	if len(got) != 2 || got["a.yml"] != "A" || got["b.yaml"] != "B" {
		t.Errorf("got %v, want only a.yml and b.yaml", got)
	}
}

// A name that is an expression is not a name: a required name equal to it must not be satisfied.
func TestRequiredCheckExpressionNameIsNotAName(t *testing.T) {
	src := "on:\n  pull_request:\njobs:\n  j:\n    name: x-${{ matrix.n }}\n"
	got := requiredCheckFindings([]string{"x-${{ matrix.n }}"}, map[string]string{"a.yml": src})
	if len(got) != 1 || !strings.Contains(got[0], "no workflow job produces") {
		t.Errorf("got %q", got)
	}
}

const rcOK = `on:
  push:
  pull_request:
jobs:
  alpha:
    runs-on: u
  beta:
    name: Beta check
    if: always()
    runs-on: u
  gamma:
    runs-on: u
`

func rcMutate(t *testing.T, old, new string) string {
	t.Helper()
	if !strings.Contains(rcOK, old) {
		t.Fatalf("the mutation target %q is not in the source", old)
	}
	return strings.Replace(rcOK, old, new, 1)
}

func TestRequiredCheckFindings(t *testing.T) {
	req := []string{"alpha", "Beta check", "gamma"}
	cases := []struct {
		name string
		wfs  map[string]string
		want []string
	}{
		{"all real", map[string]string{"a.yml": rcOK}, nil},
		{"the first name is gone", map[string]string{"a.yml": rcOK[:strings.Index(rcOK, "  alpha:")] + rcOK[strings.Index(rcOK, "  beta:"):]},
			[]string{"alpha: no workflow job produces this check name"}},
		{"the last name is gone", map[string]string{"a.yml": rcMutate(t, "  gamma:\n    runs-on: u\n", "")},
			[]string{"gamma: no workflow job produces this check name"}},
		{"required by id but the job has another name", map[string]string{"a.yml": rcMutate(t, "  alpha:\n", "  alpha:\n    name: Other\n")},
			[]string{"alpha: no workflow job produces this check name"}},
		{"job-level if that can skip the first", map[string]string{"a.yml": rcMutate(t, "  alpha:\n", "  alpha:\n    if: github.event_name == 'push'\n")},
			[]string{"alpha: a.yml job alpha has the job-level if: github.event_name == 'push', which can skip it"}},
		{"job-level if that can skip the last", map[string]string{"a.yml": rcMutate(t, "  gamma:\n", "  gamma:\n    if: success()\n")},
			[]string{"gamma: a.yml job gamma has the job-level if: success(), which can skip it"}},
		{"always() is the one allowed condition", map[string]string{"a.yml": rcMutate(t, "  gamma:\n", "  gamma:\n    if: always()\n")}, nil},
		{"a matrix job", map[string]string{"a.yml": rcMutate(t, "  alpha:\n    runs-on: u\n", "  alpha:\n    strategy:\n      matrix:\n        n: [1]\n")},
			[]string{"alpha: a.yml job alpha is a matrix job, so its checks are named alpha (1), ..."}},
		{"a name that is an expression", map[string]string{"a.yml": rcMutate(t, "  alpha:\n", "  alpha:\n    name: x-${{ matrix.n }}\n")},
			[]string{"alpha: no workflow job produces this check name"}},
		{"no pull_request event", map[string]string{"a.yml": rcMutate(t, "  pull_request:\n", "")},
			[]string{"alpha: a.yml has no pull_request event", "Beta check: a.yml has no pull_request event", "gamma: a.yml has no pull_request event"}},
		{"pull_request event in flow form", map[string]string{"a.yml": rcMutate(t, "  pull_request:\n", "  pull_request: {branches: [main]}\n")},
			[]string{"alpha: a.yml pull_request event is unreadable", "Beta check: a.yml pull_request event is unreadable", "gamma: a.yml pull_request event is unreadable"}},
		{"names spread over two files, the second without pull_request",
			map[string]string{"a.yml": "on:\n  pull_request:\njobs:\n  alpha:\n    runs-on: u\n  gamma:\n    runs-on: u\n", "b.yml": "on:\n  push:\njobs:\n  beta:\n    name: Beta check\n    runs-on: u\n"},
			[]string{"Beta check: b.yml has no pull_request event"}},
		{"an unreadable workflow cannot hide the job from the others", map[string]string{"a.yml": rcOK, "b.yml": "name: only\n"}, nil},
		{"only an unreadable workflow", map[string]string{"a.yml": "name: only\n"},
			[]string{"alpha: no workflow job produces this check name", "Beta check: no workflow job produces this check name", "gamma: no workflow job produces this check name"}},
		{"no workflow at all", nil, []string{"no workflow file was read, so no required check was verified"}},
	}
	for _, c := range cases {
		got := requiredCheckFindings(req, c.wfs)
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%s:\n got  %q\n want %q", c.name, got, c.want)
		}
	}
	if got := requiredCheckFindings(nil, map[string]string{"a.yml": rcOK}); len(got) != 1 || !strings.Contains(got[0], "empty") {
		t.Errorf("an empty required list must be a finding, got %q", got)
	}
}
