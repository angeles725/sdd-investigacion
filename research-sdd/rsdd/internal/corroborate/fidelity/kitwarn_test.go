package fidelity

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitsite"
)

// A run without --toolbelt, --fixtures and RSDD_FIDELITY_DECOMPILER needs the toolbelt directory twice (the
// fixtures, then the decompiler). With an invalid RESEARCH_SDD_KIT that falls through to the default checkout the
// resolver's warning is printed once, on stderr; stdout and the exit code are the ones of a valid variable.
func TestInvalidKitWarnsOnceWhenTheToolbeltIsNeededTwice(t *testing.T) {
	fixture := "toolbelt/tests/fixtures/java-fidelity-experiment/A.java"
	k := kitsite.New(t, kitsite.NoPath, nil, fixture)
	wantOut := "DEGRADED: reason=javac-missing (no usable javac; set RSDD_FIDELITY_JAVAC or put a JDK on PATH)\n"

	out, errOut, rc := k.Run(Run, nil, k.Root, k.Home)
	if msg := kitsite.Compare(out, errOut, rc, wantOut, "", exitDegraded); msg != "" {
		t.Fatalf("valid RESEARCH_SDD_KIT: %s", msg)
	}
	bare := k.Bare(t)
	out, errOut, rc = k.Run(Run, nil, bare, k.Home)
	if msg := kitsite.Compare(out, errOut, rc, wantOut, kitsite.InvalidKitWarning(bare), exitDegraded); msg != "" {
		t.Fatalf("invalid RESEARCH_SDD_KIT: %s", msg)
	}
}
