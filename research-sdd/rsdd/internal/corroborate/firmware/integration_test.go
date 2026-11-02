//go:build linux

package firmware

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestRealBubblewrapRunsTheAnalyzerWithoutCapabilitiesOrNetwork runs the whole command with the real
// bubblewrap and the production dependencies, against a fake analyzer that reports what it can see. It is
// skipped when bubblewrap is absent, not root-owned, or cannot create its namespaces here.
func TestRealBubblewrapRunsTheAnalyzerWithoutCapabilitiesOrNetwork(t *testing.T) {
	if testing.Short() {
		t.Skip("runs the real sandbox")
	}
	bwrap := defaultBwrap
	if fi, err := os.Stat(bwrap); err != nil || !fi.Mode().IsRegular() {
		t.Skip("no " + bwrap)
	}
	if out, err := exec.Command(bwrap, "--ro-bind", "/", "/", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL", "true").CombinedOutput(); err != nil {
		t.Skipf("bubblewrap cannot create its namespaces here: %v: %s", err, out)
	}
	w := newWorld(t)
	w.d = realDeps()
	w.env["RSDD_BWRAP"] = ""
	w.useOverride(w.analyzer("probe", fakeBinwalk(
		`printf '0 0x0 %s\n' "$(grep CapEff /proc/self/status | tr -d '\t ')"
printf '1 0x1 net:%s\n' "$(tail -n +3 /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ',')"
printf '2 0x2 home:%s\n' "$HOME"`)))
	if code := w.run(w.input(), w.path("real")); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, w.err.String())
	}
	var seen []string
	for _, s := range at(t, w.report("real"), "signatures").([]any) {
		seen = append(seen, at(t, s, "description").(string))
	}
	got := strings.Join(seen, "|")
	if got != "CapEff:0000000000000000|net:lo,|home:/tmp/rsdd/home" {
		t.Errorf("the analyzer saw %q inside the sandbox", got)
	}
	w.verifyManifest("real")
}
