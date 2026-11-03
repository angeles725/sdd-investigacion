//go:build linux

package pcap

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestMain lets the test binary stand in for rsdd: started with the hidden helper command it becomes the rlimit
// re-exec helper (the sandboxed tools run through it), so no installed binary is needed.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	syscall.Umask(0o022)
	os.Exit(m.Run())
}

const toolbelt = "../../core/adapter/testdata/frozen" // frozen oracle copies of the toolbelt adapter modules

// python is the interpreter the manifest tool and the oracle run under: python3.12 when installed (the version
// the legacy tools are held to), else python3. A missing interpreter FAILS the test (a skipped test proves nothing).
func python(t testing.TB) string {
	t.Helper()
	for _, name := range []string{"python3.12", "python3"} {
		if py, err := exec.LookPath(name); err == nil {
			return py
		}
	}
	t.Fatal("python3 is required for these tests and was not found")
	return ""
}

// manifestCLI is the real analysis_manifest.py both implementations hand their evidence to.
func manifestCLI(t testing.TB) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join(toolbelt, "analysis_manifest.py"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// A rig is a fake sandbox host: a bwrap that runs the command after "--" in the working directory, and a
// capinfos and tshark that print canned files from data/. The fakes live in one PATH directory, so the tools
// resolve exactly as they would from a real install while no real tshark or Bubblewrap is needed.
type rig struct {
	dir  string // PATH directory holding the fakes
	data string
}

const fakeBwrap = `#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
`

// The fakes honour fail-<step> (exit with that status) and sleep-<step> (sleep that many seconds) marker files.
const fakeCapinfos = `#!/bin/sh
d="$(dirname "$0")/data"
[ -f "$d/sleep-capinfos" ] && sleep "$(cat "$d/sleep-capinfos")"
cat "$d/capinfos.txt"
[ -f "$d/fail-capinfos" ] && exit "$(cat "$d/fail-capinfos")"
exit 0
`

const fakeTshark = `#!/bin/sh
d="$(dirname "$0")/data"
step() { [ -f "$d/sleep-$1" ] && sleep "$(cat "$d/sleep-$1")"; cat "$d/$2"; rc=$?; [ -f "$d/fail-$1" ] && exit "$(cat "$d/fail-$1")"; exit $rc; }
case "$*" in
  "-v") cat "$d/version.txt" ;;
  "-q -z io,phs -r input/capture.pcap") step phs phs.txt ;;
  "-T fields -e tcp.stream -r input/capture.pcap") step fields fields.txt ;;
  "-q -z follow,tcp,raw,"*) n="${3##*,}"; step "follow-$n" "follow-$n.txt" ;;
  "-q -z conv,tcp -z conv,udp -r input/capture.pcap") step conv conv.txt ;;
  *) echo "fake tshark: unexpected arguments: $*" >&2; exit 9 ;;
esac
`

const defaultPHS = `
===================================================================
Protocol Hierarchy Statistics
Filter:

eth                                      frames:2 bytes:84
  ip                                     frames:1 bytes:42
    tcp                                  frames:1 bytes:42
  arp                                    frames:1 bytes:42
===================================================================
`

const defaultConv = `================================================================================
TCP Conversations
Filter:<No Filter>
                                               |       <-      | |       ->      | |     Total     |    Relative    |   Duration   |
                                               | Frames  Bytes | | Frames  Bytes | | Frames  Bytes |      Start     |              |
192.168.1.2:4321     <-> 192.168.1.1:80             1      60         1      54         2     114     0.000000000         0.0010
10.0.0.9:5000        <-> 10.0.0.1:22                3     300         4     400         7     700     0.100000000         1.5000
================================================================================
================================================================================
UDP Conversations
Filter:<No Filter>
                                               |       <-      | |       ->      | |     Total     |    Relative    |   Duration   |
10.0.0.7:5353        <-> 10.0.0.5:53                1      80         1      60         2     140     0.200000000         0.0100
================================================================================
`

func newRig(t testing.TB) *rig {
	t.Helper()
	root := t.TempDir()
	r := &rig{dir: filepath.Join(root, "bin"), data: filepath.Join(root, "bin", "data")}
	if err := os.MkdirAll(r.data, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"bwrap": fakeBwrap, "capinfos": fakeCapinfos, "tshark": fakeTshark} {
		if err := os.WriteFile(filepath.Join(r.dir, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, util := range []string{"cat", "dirname", "sleep", "cp"} { // what the fakes run; PATH is the rig alone
		path, err := exec.LookPath(util)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(path, filepath.Join(r.dir, util)); err != nil {
			t.Fatal(err)
		}
	}
	r.set("version.txt", "TShark (Wireshark) 4.2.0 (fake)\nsecond line\n")
	r.set("capinfos.txt", capinfosSample)
	r.set("phs.txt", defaultPHS)
	r.set("conv.txt", defaultConv)
	r.set("fields.txt", "0\n\n1\n")
	r.set("follow-0.txt", "===\nNode 0: 192.168.1.2:4321\nNode 1: 192.168.1.1:80\n48454c4c4f\n\t574f524c44\n===\n")
	r.set("follow-1.txt", "===\nNode 0: 10.0.0.9:5000\nNode 1: 10.0.0.1:22\n4142\n===\n")
	return r
}

// set writes a canned output or marker file.
func (r *rig) set(name, content string) {
	if err := os.WriteFile(filepath.Join(r.data, name), []byte(content), 0o644); err != nil {
		panic(err)
	}
}

// env is the environment a run sees: PATH is the rig directory alone, so no tool of the host can leak in. A python
// interpreter may still be linked in as python3 (the legacy side starts the manifest tool with it); an empty py leaves
// whatever python3 the rig already holds (the fake manifest tool of fakeManifest).
func (r *rig) env(py string, extra ...string) []string {
	if py != "" {
		link := filepath.Join(r.dir, "python3")
		_ = os.Remove(link)
		if err := os.Symlink(py, link); err != nil {
			panic(err)
		}
	}
	env := []string{"PATH=" + r.dir, "HOME=" + filepath.Dir(r.dir)}
	return append(env, extra...)
}

// fakeManifestMarker, present in a rig's PATH directory, makes the in-process manifest steps of a run in that rig
// the fake below instead of the real ones. The seam is installed once (init), so parallel tests stay independent:
// each run finds its own rig through its PATH.
const fakeManifestMarker = "fake-manifest"

func init() {
	real := manifestVerb
	manifestVerb = func(args []string, s cli.Stdio) int {
		dir := s.Env("PATH")
		if _, err := os.Stat(filepath.Join(dir, fakeManifestMarker)); err != nil {
			return real(args, s)
		}
		return fakeManifestVerb(filepath.Join(dir, "data"), args, s)
	}
}

// fakeManifestVerb stands in for the manifest tool, so a run's manifest steps need no real tool: "create" copies
// the spec it was given to the manifest path (the frozen spec is what the command asked the tool to record),
// "validate" and "verify" succeed. A fail-manifest-<verb> marker file in data makes that verb print its content
// and exit 2.
func fakeManifestVerb(data string, args []string, s cli.Stdio) int {
	verb := args[0]
	if b, err := os.ReadFile(filepath.Join(data, "fail-manifest-"+verb)); err == nil {
		_, _ = s.Err.Write(b)
		return 2
	}
	if verb == "create" {
		var spec, out string
		for i := 1; i+1 < len(args); i++ {
			switch args[i] {
			case "--spec":
				spec = args[i+1]
			case "--output":
				out = args[i+1]
			}
		}
		b, err := os.ReadFile(spec)
		if err != nil || os.WriteFile(out, b, 0o644) != nil {
			return 1
		}
	}
	return 0
}

// fakeManifest makes the manifest steps of runs in this rig fake (see fakeManifestVerb): a run needs no real tool.
func (r *rig) fakeManifest() {
	if err := os.WriteFile(filepath.Join(r.dir, fakeManifestMarker), nil, 0o644); err != nil {
		panic(err)
	}
}

// writePcap writes a capture file with libpcap magic and a fixed body.
func writePcap(t testing.TB, path string) {
	t.Helper()
	body := append([]byte{0xd4, 0xc3, 0xb2, 0xa1, 2, 0, 4, 0}, []byte("fixed capture body for the fakes")...)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

var fixedClock = time.Date(2026, 11, 2, 12, 0, 0, 123456000, time.UTC)

// goRun runs a command in-process in cwd with the given environment.
func goRun(run func([]string, cli.Stdio) int, cwd string, env []string, args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	lookup := func(key string) string {
		for i := len(env) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(env[i], key+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb, Env: lookup,
		Environ: func() []string { return append([]string(nil), env...) },
		Clock:   func() time.Time { return fixedClock }, Cwd: cwd,
	}
	code = run(append([]string(nil), args...), s)
	return code, out.String(), errb.String()
}

var mountOnce sync.Once

// hostReady creates the shared /tmp/rsdd mount point once, before parallel runs race to create it.
func hostReady(t testing.TB) {
	t.Helper()
	mountOnce.Do(func() {
		if err := os.MkdirAll("/tmp/rsdd", 0o700); err != nil {
			t.Fatal(err)
		}
	})
}
