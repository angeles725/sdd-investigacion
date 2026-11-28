//go:build unix

package console

import (
	"bytes"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// stdioIn is a Stdio for w with its own clock; the environment is the world's.
func (w *world) stdioIn(clock func() time.Time, extra ...string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	env := w.environ(extra)
	var o, e bytes.Buffer
	return cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: lookup(env),
		Environ: func() []string { return env }, Clock: clock, Cwd: w.dir}, &o, &e
}

// The stamp is `date -u`: UTC whatever zone the clock is in, the same value in the file name and in the header.
func TestTheTimestampIsUTC(t *testing.T) {
	w := newWorld(t)
	w.stub(ps, `printf 'r\n'`)
	zone := time.FixedZone("far-east", 5*3600+1800)
	clock := func() time.Time { return time.Date(2026, 11, 29, 3, 29, 58, 0, zone) } // 2026-11-28 21:59:58 UTC
	s, out, errb := w.stdioIn(clock)
	if rc := Run([]string{"run", "tgt", "COM7", "9600", "x"}, s); rc != 0 || errb.Len() != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
	const name = "tgt/sources/probes/serial-COM7-20261128T215958Z.txt"
	b, err := os.ReadFile(w.dir + "/" + name)
	if err != nil {
		t.Fatalf("evidence file not at the UTC name: %v", err)
	}
	if want := "# serial-console run 20261128T215958Z\n# port: COM7  baud: 9600  cmd: x\n---\nr\n"; string(b) != want {
		t.Errorf("file = %q, want %q", b, want)
	}
	if !strings.Contains(out.String(), "-> "+name+" ==\n") || !strings.Contains(out.String(), "preserved: "+name+"  (cite as [CERT-hw] evidence; rc=0)\n") {
		t.Errorf("stdout = %q", out.String())
	}
}

// A shell command substitution drops NUL bytes (with a warning of its own, which the port does not print), so
// "O<NUL>K" reads as OK.
func TestCheckDropsNULBytes(t *testing.T) {
	w := newWorld(t)
	w.stub(ps, `printf 'O\000K\r\n'`)
	s, out, errb := w.stdioIn(time.Now)
	if rc := Run([]string{"check"}, s); rc != 0 || out.String() != "interop: OK (powershell.exe reachable)\n" || errb.Len() != 0 {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
}

// The evidence file is created with the mode tee gives it (0666 under the umask), not a private one.
func TestEvidenceFileModeIsTeeMode(t *testing.T) {
	w := newWorld(t)
	w.stub(ps, `:`)
	old := umaskSet(0o022)
	defer umaskSet(old)
	s, _, _ := w.stdioIn(time.Now)
	if rc := Run([]string{"run", "tgt", "COM3", "9600", "x"}, s); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	ents, err := os.ReadDir(w.dir + "/tgt/sources/probes")
	if err != nil || len(ents) != 1 {
		t.Fatalf("entries %v, err %v", ents, err)
	}
	fi, _ := ents[0].Info()
	if fi.Mode().Perm() != 0o644 {
		t.Errorf("evidence file mode = %v, want 0644 (0666 under umask 022)", fi.Mode().Perm())
	}
	di, _ := os.Stat(w.dir + "/tgt/sources/probes")
	if di.Mode().Perm() != 0o755 {
		t.Errorf("created directory mode = %v, want 0755 (0777 under umask 022)", di.Mode().Perm())
	}
}
