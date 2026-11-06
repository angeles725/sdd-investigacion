package goimpact_test

import (
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

// With the C9 blind spots in play stage-issues is FULL; the mapping itself is shown by clearing the blind-spot
// reasons (never the exemption) and classifying the same file.
func TestRealTreeSmokeStageIssues(t *testing.T) {
	repo, f := realRepo(t), mod+"internal/retro/stageissues/run.go"
	r := run("--repo", repo, f)
	if r.rc != 0 || !strings.HasPrefix(r.out, "FULL\t"+f+"\tunclassifiable bash caller: ") {
		t.Errorf("default run: %+v", r)
	}
	m, err := goimpact.Load(repo)
	if err != nil {
		t.Fatal(err)
	}
	known := map[goimpact.Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	files, err := goimpact.ScanBash(repo, func(c goimpact.Command) bool { return known[c] })
	if err != nil {
		t.Fatal(err)
	}
	for i := range files {
		files[i].Mentions, files[i].Empty = nil, false
	}
	got := goimpact.NewAnalysis(m, files, 100).Classify(f)
	want := "SHIM\t" + f + "\tresearch-sdd/toolbelt/stage-retro-issues.sh\tretro stage-issues"
	found := false
	for _, l := range got {
		found = found || l == want
	}
	if !found || !strings.HasPrefix(got[len(got)-1], "CLOSURE\t"+f+"\t") {
		t.Errorf("missing %q in %q", want, got)
	}
}

func TestRealTreeTestkitIsGoTestOnly(t *testing.T) {
	f := mod + "internal/testkit/parity/spec.go"
	r := run("--repo", realRepo(t), f)
	if r.out != "NONE\t"+f+"\tgo-test-only\n" {
		t.Errorf("%+v", r)
	}
}
