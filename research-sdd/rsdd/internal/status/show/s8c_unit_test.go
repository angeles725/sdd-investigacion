//go:build unix

package show

import (
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
)

// teeth-SX-AWK (S8c): the bash script dropped the awk exit check before `mv`, so a failed awk clobbered the state
// file. The port builds the replacement in memory, so the one failure it can have between building it and the
// rename is the temp file refusing the bytes. The test makes that happen (RLIMIT_FSIZE, SIGXFSZ ignored: the write
// returns EFBIG) and requires the error, the untouched state file and no leftover temp file. A rewrite that ignores
// the write error, or that writes the state file in place, fails it.
func TestRewriteWriteFailureKeepsTheStateFile(t *testing.T) {
	var old syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_FSIZE, &old); err != nil {
		t.Skipf("no RLIMIT_FSIZE: %v", err)
	}
	root := t.TempDir()
	state := filepath.Join(root, "RESEARCH-STATE.md")
	const orig = "# T\n\nthe declared state\n"
	if err := os.WriteFile(state, []byte(orig), 0o644); err != nil {
		t.Fatal(err)
	}
	s, _, _ := stdio(root)
	c := &ctx{s: s, state: state}
	signal.Ignore(syscall.SIGXFSZ)
	defer signal.Reset(syscall.SIGXFSZ)
	if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &syscall.Rlimit{Cur: 8, Max: old.Max}); err != nil {
		t.Skipf("cannot lower RLIMIT_FSIZE: %v", err)
	}
	err := c.rewrite(orig, "<!-- research-state.v1 -->\nschema: research-state.v1\n<!-- /research-state.v1 -->")
	if rerr := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &old); rerr != nil {
		t.Fatalf("restoring RLIMIT_FSIZE: %v", rerr)
	}
	if err == nil {
		t.Fatal("rewrite reported success although the temp file could not take the bytes")
	}
	if b, _ := os.ReadFile(state); string(b) != orig {
		t.Errorf("the state file was clobbered: %q", b)
	}
	if ents, _ := os.ReadDir(root); len(ents) != 1 {
		t.Errorf("leftover entries: %v", ents)
	}
}
