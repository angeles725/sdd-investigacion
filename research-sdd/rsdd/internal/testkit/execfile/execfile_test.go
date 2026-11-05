package execfile_test

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// A fork that is in progress (os/exec holds syscall.ForkLock for writing) must keep Write from opening the file:
// otherwise the child inherits the write descriptor and an exec of the new file fails with ETXTBSY.
func TestWriteWaitsForAForkInProgress(t *testing.T) {
	p := filepath.Join(t.TempDir(), "bin", "stub")
	syscall.ForkLock.Lock()
	done := make(chan struct{})
	go func() {
		execfile.Write(t, p, "#!/bin/sh\nexit 0\n")
		close(done)
	}()
	select {
	case <-done:
		syscall.ForkLock.Unlock()
		t.Fatal("Write completed while a fork held syscall.ForkLock")
	case <-time.After(200 * time.Millisecond):
	}
	if _, err := os.Stat(p); err == nil {
		syscall.ForkLock.Unlock()
		t.Fatal("the file was created while a fork held syscall.ForkLock")
	}
	syscall.ForkLock.Unlock()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Write did not complete after the fork released syscall.ForkLock")
	}
}

func TestWriteCreatesAnExecutableWithItsParents(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a", "b", "stub")
	execfile.Write(t, p, "#!/bin/sh\necho hi\n")
	b, err := os.ReadFile(p)
	if err != nil || string(b) != "#!/bin/sh\necho hi\n" {
		t.Fatalf("content = %q, %v", b, err)
	}
	st, err := os.Stat(p)
	if err != nil || st.Mode().Perm() != 0o755 {
		t.Fatalf("mode = %v, %v; want 0755 whatever the umask", st.Mode().Perm(), err)
	}
	execfile.Write(t, p, "#!/bin/sh\nexit 3\n") // an existing file is replaced
	if b, _ := os.ReadFile(p); string(b) != "#!/bin/sh\nexit 3\n" {
		t.Fatalf("rewrite: %q", b)
	}
}

func TestRunsTheWrittenFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "stub")
	execfile.Write(t, p, "#!/bin/sh\nexit 7\n")
	proc, perr := os.StartProcess(p, []string{p}, &os.ProcAttr{})
	if perr != nil {
		t.Fatal(perr)
	}
	st, _ := proc.Wait()
	if st.ExitCode() != 7 {
		t.Fatalf("exit = %d, want 7", st.ExitCode())
	}
}
