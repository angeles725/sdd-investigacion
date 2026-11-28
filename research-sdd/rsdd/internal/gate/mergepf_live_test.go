package gate

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Kit issue #2852: the path-filter reader (pfScanWorkflow) refuses to evaluate ANY required check when one job of
// any workflow has a `name:` it cannot read, and a `${{ ... }}` name is such a name. The gate stays strict on
// purpose (a line scanner cannot model YAML expressions), so the defect is cured in the workflows: no job may carry
// a templated name. These tests read the LIVE workflows of this tree, never a fixture copy, so a later workflow
// edit that brings the shape back fails here instead of silently blocking every docs-only PR with ci_missing.

// liveRoot is the repository root, from this package (research-sdd/rsdd/internal/gate).
const liveRoot = "../../../.."

// liveWorkflows returns the live .github/workflows files (tree path -> text); it skips with a typed message when
// the tree has no workflows directory (an exported copy of the module, a vendored checkout).
func liveWorkflows(t *testing.T) map[string]string {
	t.Helper()
	dir := filepath.Join(liveRoot, ".github", "workflows")
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Skipf("SKIP: no-live-workflows: %s is not readable (%v); the live-workflow guards need the repository root", dir, err)
	}
	wfs := map[string]string{}
	for _, e := range ents {
		if e.IsDir() || !yamlName.MatchString(e.Name()) {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		wfs[".github/workflows/"+e.Name()] = string(b)
	}
	if len(wfs) == 0 {
		t.Skipf("SKIP: no-live-workflows: %s holds no .yml/.yaml file", dir)
	}
	return wfs
}

// liveRun is a --merge run whose required checks never reported, over the live workflows at both the PR base and
// the head tree, so the path filters of the real files decide.
func liveRun(t *testing.T, files string) (string, int) {
	t.Helper()
	wfs := liveWorkflows(t)
	sc := newScn(t)
	sc.workflows = map[string]map[string]string{hPRBase: wfs, hHead: wfs}
	sc.checks = runsJSON("pr-validation:completed:success")
	sc.files = files
	out, _, rc := sc.run(mergeArgs7()...)
	return out, rc
}

func TestPathFilterLiveWorkflowsDocsOnly(t *testing.T) {
	allow := allowLine("passive", bound7)
	merged := "merge-gate: merged: PR #7 (head=" + hHead + " cwd=/repo)\nmerge-gate: closure-evidence: skipped: --no-closure-evidence\n"
	skip := func(chk string) string {
		return strings.Replace(strings.Replace(skipNote, "%s", chk, 1), "%s", wfPath, 1)
	}
	t.Run("docs-only diff over the live workflows: the filters are evaluated and both checks are skipped", func(t *testing.T) {
		out, rc := liveRun(t, filesJSON("odd/tasks/x.md", "docs/yy.md"))
		if strings.Contains(out, "job name shape") {
			t.Fatalf("a live workflow has a job name the path-filter reader cannot read, so the gate refuses every docs-only PR (kit issue #2852): out=%q rc=%d", out, rc)
		}
		want := strings.Replace(skip("shellcheck"), "%d", "2", 1) + strings.Replace(skip("toolbelt-tests"), "%d", "2", 1) + allow + merged
		if out != want || rc != 0 {
			t.Fatalf("out=%q rc=%d want=%q", out, rc, want)
		}
	})
	t.Run("a Go change over the live workflows is still refused ci_missing", func(t *testing.T) {
		out, rc := liveRun(t, filesJSON("research-sdd/rsdd/internal/gate/mergepf.go"))
		if out != missingCI || rc != 1 {
			t.Fatalf("out=%q rc=%d", out, rc)
		}
	})
}

// TestLiveWorkflowJobNamesAreLiteral fails when ANY live workflow job carries a `name:` the reader cannot take
// literally (`${{ ... }}`, empty, or a YAML indicator), which is the whole of what makes it give up.
func TestLiveWorkflowJobNamesAreLiteral(t *testing.T) {
	wfs := liveWorkflows(t)
	var paths []string
	for p := range wfs {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		if sc := pfScanWorkflow(cmdSub(wfs[p]), "no-such-check"); strings.HasPrefix(sc.unsup, "job name shape of ") {
			t.Errorf("%s: %s: a job `name:` containing `${{` (or empty, or a YAML indicator) makes `rsdd gate merge` give up on the path filters of EVERY required check, so no docs-only PR can merge (kit issue #2852). Remove the `name:` and let GitHub name the job from its id (a matrix job becomes `<id> (<value>)`).", p, sc.unsup)
		}
		inJobs := false
		for _, l := range strings.Split(wfs[p], "\n") {
			if strings.HasPrefix(l, "jobs:") {
				inJobs = true
				continue
			}
			if inJobs && l != "" && l[0] != ' ' && l[0] != '#' {
				inJobs = false
			}
			if inJobs && strings.HasPrefix(l, "    name:") && strings.Contains(l, "${{") {
				t.Errorf("%s: job-level `name:` contains `${{` (%q); kit issue #2852: the gate cannot read it and refuses every docs-only PR", p, strings.TrimSpace(l))
			}
		}
	}
}
