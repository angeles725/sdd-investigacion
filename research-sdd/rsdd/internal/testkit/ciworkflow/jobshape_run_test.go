package ciworkflow

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// shapeWorkflows are the real workflow files whose job shape is guarded.
var shapeWorkflows = []string{".github/workflows/toolbelt-tests.yml"}

func TestWorkflowJobsKeepTheirShape(t *testing.T) {
	root := filepath.Dir(kitroot.Dir(t))
	for _, wf := range shapeWorkflows {
		src, err := os.ReadFile(filepath.Join(root, wf))
		if err != nil {
			t.Fatalf("%s: cannot read the workflow, so its jobs were not checked: %v", wf, err)
		}
		for _, f := range checkJobShape(string(src)) {
			t.Errorf("%s: %s", wf, f)
		}
	}
}

// okShape is a conforming workflow with two shard jobs, a join and shellcheck, in that order.
const okShape = `name: x
on:
  pull_request:
jobs:
  shard-a:
    runs-on: ubuntu
    strategy:
      matrix:
        shard: [1, 2]
    steps:
      - name: Run
        run: make
      - name: Upload shard manifest
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: m-${{ matrix.shard }}
          if-no-files-found: error
  shard-b:
    runs-on: ubuntu
    strategy:
      matrix:
        shard: [1]
    steps:
      - name: Upload
        if: always()
        uses: actions/upload-artifact@v4
        with:
          if-no-files-found: error
  toolbelt-tests:
    needs: [shard-a, shard-b]
    if: always()
    runs-on: ubuntu
    steps:
      - name: Require every shard job green
        run: |
          [ "${{ needs.shard-a.result }}" = success ]
          [ "${{ needs.shard-b.result }}" = success ]
  shellcheck:
    runs-on: ubuntu
    steps:
      - run: shellcheck x
`

// mutate replaces old with new once and fails the test when old is absent, so a case can never pass because its
// mutation changed nothing.
func mutate(t *testing.T, src, old, new string) string {
	t.Helper()
	if !strings.Contains(src, old) {
		t.Fatalf("the mutation target %q is not in the source", old)
	}
	return strings.Replace(src, old, new, 1)
}

func TestCheckJobShapeFindings(t *testing.T) {
	cases := []struct {
		name string
		src  func(t *testing.T) string
		want []string
	}{
		{"conforming source", func(t *testing.T) string { return okShape }, nil},
		{"a list nested in the upload step does not split it", func(t *testing.T) string {
			return mutate(t, okShape, "          name: m-${{ matrix.shard }}\n", "          name: m-${{ matrix.shard }}\n          path:\n            - a\n            - b\n")
		}, nil},
		{"join gets a name", func(t *testing.T) string {
			return mutate(t, okShape, "  toolbelt-tests:\n", "  toolbelt-tests:\n    name: toolbelt-tests\n")
		}, []string{"toolbelt-tests: has the name: toolbelt-tests"}},
		{"join loses always()", func(t *testing.T) string {
			return mutate(t, okShape, "    needs: [shard-a, shard-b]\n    if: always()\n", "    needs: [shard-a, shard-b]\n")
		}, []string{"toolbelt-tests: if: is absent, want it to contain always()"}},
		{"join if is another condition", func(t *testing.T) string {
			return mutate(t, okShape, "    if: always()\n    runs-on: ubuntu\n    steps:\n      - name: Require", "    if: success()\n    runs-on: ubuntu\n    steps:\n      - name: Require")
		}, []string{`toolbelt-tests: if: is "success()", want it to contain always()`}},
		{"join does not need the first shard", func(t *testing.T) string {
			return mutate(t, okShape, "needs: [shard-a, shard-b]", "needs: [shard-b]")
		}, []string{"shard-a: is a matrix job that toolbelt-tests does not need"}},
		{"join does not need the last shard", func(t *testing.T) string {
			return mutate(t, okShape, "needs: [shard-a, shard-b]", "needs: shard-a")
		}, []string{"shard-b: is a matrix job that toolbelt-tests does not need"}},
		{"join needs nothing", func(t *testing.T) string {
			return mutate(t, okShape, "    needs: [shard-a, shard-b]\n", "")
		}, []string{
			"toolbelt-tests: needs names no job",
			"shard-a: is a matrix job that toolbelt-tests does not need",
			"shard-b: is a matrix job that toolbelt-tests does not need",
		}},
		{"join needs a job that is not there", func(t *testing.T) string {
			return mutate(t, okShape, "needs: [shard-a, shard-b]", "needs: [shard-a, shard-b, ghost]")
		}, []string{"toolbelt-tests: needs ghost, which is not a job", "toolbelt-tests: never reads needs.ghost.result"}},
		{"join needs a job that is not a matrix", func(t *testing.T) string {
			return mutate(t, okShape, "needs: [shard-a, shard-b]", "needs: [shard-a, shard-b, shellcheck]")
		}, []string{"shellcheck: a shard job named in needs is not a matrix job", "toolbelt-tests: never reads needs.shellcheck.result"}},
		{"join stops reading the first result", func(t *testing.T) string {
			return mutate(t, okShape, `          [ "${{ needs.shard-a.result }}" = success ]`+"\n", "")
		}, []string{"toolbelt-tests: never reads needs.shard-a.result"}},
		{"join stops reading the last result", func(t *testing.T) string {
			return mutate(t, okShape, `          [ "${{ needs.shard-b.result }}" = success ]`+"\n", "          # needs.shard-b.result\n")
		}, []string{"toolbelt-tests: never reads needs.shard-b.result"}},
		{"shard name uses an expression", func(t *testing.T) string {
			return mutate(t, okShape, "  shard-b:\n    runs-on: ubuntu\n", "  shard-b:\n    name: b-${{ matrix.shard }}\n    runs-on: ubuntu\n")
		}, []string{"shard-b: name contains ${{"}},
		{"first shard is no longer a matrix job", func(t *testing.T) string {
			return mutate(t, okShape, "    strategy:\n      matrix:\n        shard: [1, 2]\n", "")
		}, []string{"shard-a: a shard job named in needs is not a matrix job"}},
		{"last shard is no longer a matrix job", func(t *testing.T) string {
			return mutate(t, okShape, "    strategy:\n      matrix:\n        shard: [1]\n", "    strategy:\n      fail-fast: false\n")
		}, []string{"shard-b: a shard job named in needs is not a matrix job"}},
		{"upload step loses if: always()", func(t *testing.T) string {
			return mutate(t, okShape, "      - name: Upload shard manifest\n        if: always()\n", "      - name: Upload shard manifest\n")
		}, []string{"shard-a: the upload step lacks if: always()"}},
		{"another step keeps its if: always(), the upload step has none", func(t *testing.T) string {
			return mutate(t, okShape, "      - name: Run\n        run: make\n      - name: Upload shard manifest\n        if: always()\n",
				"      - name: Run\n        if: always()\n        run: make\n      - name: Upload shard manifest\n")
		}, []string{"shard-a: the upload step lacks if: always()"}},
		{"upload step loses if-no-files-found: error", func(t *testing.T) string {
			return mutate(t, okShape, "          if-no-files-found: error\n  shard-b:", "          if-no-files-found: warn\n  shard-b:")
		}, []string{"shard-a: the upload step lacks if-no-files-found: error"}},
		{"last shard has no upload step", func(t *testing.T) string {
			return mutate(t, okShape, "uses: actions/upload-artifact@v4\n        with:\n          if-no-files-found: error\n  toolbelt-tests:", "uses: actions/cache@v4\n  toolbelt-tests:")
		}, []string{"shard-b: no actions/upload-artifact step"}},
		{"shellcheck gets a job-level if", func(t *testing.T) string {
			return mutate(t, okShape, "  shellcheck:\n", "  shellcheck:\n    if: github.event_name == 'push'\n")
		}, []string{"shellcheck: has the job-level if: github.event_name == 'push'"}},
		{"shellcheck is gone", func(t *testing.T) string {
			return mutate(t, okShape, "  shellcheck:\n    runs-on: ubuntu\n    steps:\n      - run: shellcheck x\n", "")
		}, []string{"shellcheck: no such job"}},
		{"join is gone", func(t *testing.T) string {
			return mutate(t, okShape, "  toolbelt-tests:", "  toolbelt-join:")
		}, []string{"toolbelt-tests: no such job", "shard-a: is a matrix job that toolbelt-tests does not need", "shard-b: is a matrix job that toolbelt-tests does not need"}},
		{"no shard job at all reads as a finding, not a pass", func(t *testing.T) string {
			return "jobs:\n  toolbelt-tests:\n    needs: x\n    if: always()\n  x:\n    runs-on: u\n  shellcheck:\n    runs-on: u\n"
		}, []string{"x: a shard job named in needs is not a matrix job", "toolbelt-tests: never reads needs.x.result", "no shard job: no job has a strategy matrix"}},
		{"unreadable jobs", func(t *testing.T) string { return "name: x\n" }, []string{"jobs: unrecognised form"}},
		{"flow-form job", func(t *testing.T) string {
			return mutate(t, okShape, "  shellcheck:\n    runs-on: ubuntu\n    steps:\n      - run: shellcheck x\n", "  shellcheck: {runs-on: ubuntu}\n")
		}, []string{"jobs: unrecognised form"}},
	}
	for _, c := range cases {
		got := checkJobShape(c.src(t))
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("%s:\n got  %q\n want %q", c.name, got, c.want)
		}
	}
}
