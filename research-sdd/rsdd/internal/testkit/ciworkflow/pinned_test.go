package ciworkflow

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// pinned says whether the workflow file and its fixture copy are the same bytes. The merge gate's differential
// tests read the fixtures as if they were the live workflows, so a workflow edited without refreshing its copy
// leaves the gate tested against a file that no longer exists (kit issue #2136).
//
// The three states are told apart: `same`, `drifted` (both read, bytes differ) and `absent` (either one cannot be
// read). A copy that is absent is never `same`.
func pinned(workflow, fixture string) string {
	a, errA := os.ReadFile(workflow)
	b, errB := os.ReadFile(fixture)
	if errA != nil || errB != nil {
		return "absent"
	}
	if bytes.Equal(a, b) {
		return "same"
	}
	return "drifted"
}

// pinnedCopies pairs each real workflow (relative to the repository root) with its copy under the merge-gate
// fixtures (relative to research-sdd/toolbelt/tests/fixtures/merge-gate).
var pinnedCopies = []struct{ workflow, fixture string }{
	{".github/workflows/toolbelt-tests.yml", "wf-real-toolbelt-tests.yml"},
	{".github/workflows/pr-check.yml", "wf-real-pr-check.yml"},
}

func TestPinnedWorkflowCopies(t *testing.T) {
	root := filepath.Dir(kitroot.Dir(t))
	for _, p := range pinnedCopies {
		fx := kitroot.Path(t, "toolbelt", "tests", "fixtures", "merge-gate", p.fixture)
		if got := pinned(filepath.Join(root, p.workflow), fx); got != "same" {
			t.Errorf("%s: the copy %s is %s; refresh it with cp in the same commit as the workflow", p.workflow, p.fixture, got)
		}
	}
}

// The guard must bite: equal bytes are `same`, one changed byte is `drifted`, a missing file on either side is
// `absent`.
func TestPinnedControls(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	wf := write("wf.yml", "on:\n  push:\njobs:\n  a:\n")
	cases := []struct{ name, fixture, want string }{
		{"equal", write("same.yml", "on:\n  push:\njobs:\n  a:\n"), "same"},
		{"one byte changed", write("drift.yml", "on:\n  push:\njobs:\n  b:\n"), "drifted"},
		{"trailing newline dropped", write("nonl.yml", "on:\n  push:\njobs:\n  a:"), "drifted"},
		{"fixture missing", filepath.Join(dir, "missing.yml"), "absent"},
	}
	for _, c := range cases {
		if got := pinned(wf, c.fixture); got != c.want {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}
	if got := pinned(filepath.Join(dir, "missing-wf.yml"), cases[0].fixture); got != "absent" {
		t.Errorf("workflow missing: got %s, want absent", got)
	}
}
