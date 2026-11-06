package goimpact_test

import (
	"strings"
	"testing"
)

func TestRealTreeSmokeStageIssues(t *testing.T) {
	f := mod + "internal/retro/stageissues/run.go"
	r := run("--repo", realRepo(t), f)
	want := "SHIM\t" + f + "\tresearch-sdd/toolbelt/stage-retro-issues.sh\tretro stage-issues"
	if r.rc != 0 || !has(r.lines(), want) || !strings.Contains(r.out, "BLIND\t"+f+"\t") || strings.Contains(r.out, "FULL") {
		t.Errorf("%+v", r)
	}
	if !strings.Contains(r.summary(), "blindspot-files=") {
		t.Errorf("no CLASSES line: %q", r.out)
	}
}

func TestRealTreeTestkitIsGoTestOnly(t *testing.T) {
	f := mod + "internal/testkit/parity/spec.go"
	r := run("--repo", realRepo(t), f)
	if got := strings.Join(r.lines(), "|"); got != "NONE\t"+f+"\tgo-test-only" {
		t.Errorf("%+v", r)
	}
}
