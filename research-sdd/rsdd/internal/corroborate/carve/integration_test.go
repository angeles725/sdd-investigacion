//go:build linux

package carve

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// TestRealBubblewrapCarvesWithTheWorkerInsideTheSandbox runs the whole command with the real bubblewrap, the
// production dependencies and this test binary as the sandboxed worker (TestMain serves `corroborate carve`).
// It is skipped when bubblewrap is absent or cannot create its namespaces here, or when the test binary lives
// under /tmp, which the sandbox hides behind its own tmpfs.
func TestRealBubblewrapCarvesWithTheWorkerInsideTheSandbox(t *testing.T) {
	if testing.Short() {
		t.Skip("runs the real sandbox")
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if self == "/tmp" || strings.HasPrefix(self, "/tmp/") {
		t.Skip("the test binary is under /tmp, which the sandbox replaces with a tmpfs; set GOTMPDIR outside /tmp")
	}
	if out, err := exec.Command("/usr/bin/bwrap", "--ro-bind", "/", "/", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL", "true").CombinedOutput(); err != nil {
		t.Skipf("bubblewrap is not usable here: %v: %s", err, out)
	}
	w := newWorld(t)
	w.d = realDeps()
	in := w.write("firmware.bin", firmwareImage())
	w.mustCarve(in, w.path("real"))
	if got := strings.Join(w.files("real"), ","); got != "carves/00000004-uimage.bin,carves/00000056-squashfs-v4-le.bin,"+reportName {
		t.Errorf("tree = %s", got)
	}
	if r := w.report("real"); r.Artifact.Path == "" || !strings.HasPrefix(r.Artifact.SHA256, "sha256:") {
		t.Errorf("isolation_artifact = %+v", r.Artifact)
	}
	// A worker that fails inside the sandbox reports its own message through the parent.
	if code := w.carve(w.write("junk", []byte("junk")), w.path("junk-out")); code != 2 ||
		!strings.Contains(w.err.String(), "isolated worker failed: firmware-carve: no validated supported image found") {
		t.Errorf("exit %d stderr %q", code, w.err.String())
	}
}
