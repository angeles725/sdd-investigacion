//go:build unix

package verify

import (
	"os"
	"path/filepath"
	"testing"
)

// Intended divergences from verify-registry.sh (port and improve), each pinned here and listed in
// toolbelt/tool-registry.d/verify-registry.md. They are NOT part of the differential: the script is the defect.

// An unreadable TARGETS.md was read as empty: "no usable target paths", exit 0 in the default mode. It is degraded
// input and fails operationally, in both modes, naming the file and the cause.
func TestRegistryUnreadableTargetsIsDegradedNotClean(t *testing.T) {
	for _, mode := range [][]string{nil, {"--json"}} {
		k := newVRKit(t)
		k.targets(vrTable())
		if err := os.Chmod(k.targetsMD, 0); err != nil {
			t.Fatal(err)
		}
		if f, err := os.Open(k.targetsMD); err == nil {
			f.Close()
			t.Skip("root bypasses file permissions")
		}
		r := k.run(nil, mode...)
		rcIs(t, r, 1)
		want(t, r.stderr, "verify-registry: degraded: cannot read "+filepath.Join(k.kit, "TARGETS.md"), "the registry was NOT reconciled")
		wantNot(t, r.stdout, "Registry consistent", "Summary:")
		wantNot(t, r.stderr, "no usable target paths")
	}
}
