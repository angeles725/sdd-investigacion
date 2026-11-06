package firmware

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// TestMain lets the test binary stand in for rsdd as the rlimit re-exec helper that runBounded starts.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	os.Exit(m.Run())
}

// fakeBwrap stands in for bubblewrap: it drops every option up to "--" and runs the rest in the current
// directory (the stage). The isolation probe (/bin/sh) passes unless a "probe-fails" file sits beside it.
const fakeBwrap = `#!/bin/sh
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
case "$1" in
/bin/sh) [ -e "$(dirname "$0")/probe-fails" ] && exit 1; exit 0 ;;
esac
exec "$@"
`

// binwalk scripts used across the tests.
const (
	v2Banner = `#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk v2.3.3'; exit; }
printf '0 0x0 PNG image\n'
`
	v3Banner = `#!/bin/sh
[ "$1" = --help ] && { echo 'Usage: binwalk [OPTIONS] [FILE_NAME]'; exit; }
[ "$1" = --version ] && { echo 'binwalk 3.1.0'; exit; }
printf '0 0x0 PNG image\n'
`
)

// fake returns a banner-answering binwalk whose analysis output is body (shell commands).
func fakeBinwalk(body string) string {
	return "#!/bin/sh\n[ \"$1\" = --help ] && { echo 'Binwalk v2.3.3'; exit; }\n" + body + "\n"
}

// world is one hermetic run: a scratch directory, a fake sandbox, an injected environment and streams.
type world struct {
	t    *testing.T
	root string
	d    deps
	env  map[string]string
	out  *bytes.Buffer
	err  *bytes.Buffer
}

func newWorld(t *testing.T) *world {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("the analyzer refuses root; run the tests as an unprivileged user")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, env: map[string]string{}, out: &bytes.Buffer{}, err: &bytes.Buffer{}}
	w.mkdir("bin")
	w.exe("bin/bwrap", fakeBwrap)
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	creds := adapter.CurrentCreds()
	w.d = deps{
		creds:     func() adapter.Creds { return creds },
		mountinfo: func() (string, error) { return "1 0 0:1 / / rw - ext4 disk rw\n", nil },
		self:      func() (string, error) { return self, nil },
		safePath:  w.path("bin") + ":/usr/bin:/bin",
		bwrapUIDs: map[uint64]bool{uint64(os.Geteuid()): true},
		hostRoot:  w.path("host-rsdd"),
	}
	w.env["RSDD_BWRAP"] = w.path("bin/bwrap")
	w.env["PATH"] = "/usr/bin:/bin"
	return w
}

func (w *world) path(name string) string { return filepath.Join(w.root, name) }

func (w *world) mkdir(name string) {
	w.t.Helper()
	if err := os.MkdirAll(w.path(name), 0o755); err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) write(name string, data []byte) string {
	w.t.Helper()
	if err := os.WriteFile(w.path(name), data, 0o644); err != nil {
		w.t.Fatal(err)
	}
	return w.path(name)
}

// exe writes an executable script (0755: not group- or world-writable, whatever the umask). Parallel tests build
// worlds, so the write goes through execfile.Write: no fork can leak the open descriptor into a child (ETXTBSY).
func (w *world) exe(name, script string) string {
	w.t.Helper()
	execfile.Write(w.t, w.path(name), script)
	return w.path(name)
}

// analyzer installs a fake binwalk in its own directory and returns the directory.
func (w *world) analyzer(dir, script string) string {
	w.t.Helper()
	w.mkdir(dir)
	w.exe(dir+"/binwalk", script)
	return w.path(dir)
}

// useExplicit selects the analyzer the way a user-owned install is selected: RSDD_BINWALK.
func (w *world) useExplicit(dir string) {
	w.env["RSDD_BINWALK"] = filepath.Join(dir, "binwalk")
	w.env["PATH"] = dir + ":/usr/bin:/bin"
}

// useOverride selects the analyzer as a test override, the only way a PATH binwalk the invoking user owns
// is accepted without RSDD_BINWALK.
func (w *world) useOverride(dir string) {
	w.env["RSDD_BINWALK_TEST_ONLY"] = filepath.Join(dir, "binwalk")
	w.env["PATH"] = dir + ":/usr/bin:/bin"
}

func (w *world) stdio() cli.Stdio {
	return cli.Stdio{Out: w.out, Err: w.err, Cwd: w.root, Env: func(k string) string { return w.env[k] },
		Clock: time.Now}
}

// run is `rsdd corroborate firmware --input <input> --output <out> extra...`.
func (w *world) run(input, out string, extra ...string) int {
	w.t.Helper()
	w.out.Reset()
	w.err.Reset()
	return execute(append([]string{"--input", input, "--output", out}, extra...), w.stdio(), w.d)
}

func (w *world) mustRun(input, out string, extra ...string) {
	w.t.Helper()
	if code := w.run(input, out, extra...); code != 0 {
		w.t.Fatalf("exit %d, stderr %q", code, w.err.String())
	}
}

func (w *world) exists(name string) bool {
	_, err := os.Lstat(w.path(name))
	return err == nil
}

// report is the published firmware-static.v1.json, decoded loosely.
func (w *world) report(dir string) map[string]any {
	w.t.Helper()
	b, err := os.ReadFile(w.path(dir + "/firmware-static.v1.json"))
	if err != nil {
		w.t.Fatal(err)
	}
	var r map[string]any
	if err := json.Unmarshal(b, &r); err != nil {
		w.t.Fatal(err)
	}
	return r
}

// at walks a decoded document: at(r, "engine", "trust").
func at(t *testing.T, doc any, keys ...string) any {
	t.Helper()
	for _, k := range keys {
		m, ok := doc.(map[string]any)
		if !ok {
			t.Fatalf("%v: not an object at %q", keys, k)
		}
		doc = m[k]
	}
	return doc
}

func strs(t *testing.T, v any) []string {
	t.Helper()
	list, ok := v.([]any)
	if !ok {
		t.Fatalf("not a list: %v", v)
	}
	out := make([]string, len(list))
	for i, x := range list {
		out[i], _ = x.(string)
	}
	return out
}

func contains(list []string, sub string) bool {
	for _, s := range list {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}

// verifyManifest has the manifest tool verify the published evidence, as the slow lane of the bash suite did.
func (w *world) verifyManifest(dir string) {
	w.t.Helper()
	var out, errw bytes.Buffer
	manifest := w.path(dir + "/engine/analysis-manifest.v1.json")
	for _, args := range [][]string{{"validate", manifest}, {"verify", "--root", w.path(dir), manifest}} {
		if code := adapter.ManifestRun(args, cli.Stdio{Out: &out, Err: &errw, Cwd: w.root, Env: func(string) string { return "" }}); code != 0 {
			w.t.Fatalf("manifest %v: exit %d: %s", args[0], code, errw.String())
		}
	}
}
