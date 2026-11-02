package carve

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

type report struct {
	Schema string `json:"schema"`
	Carves []struct {
		Kind   string `json:"kind"`
		Offset int64  `json:"offset"`
		Size   int64  `json:"size"`
		Path   string `json:"path"`
		SHA256 string `json:"sha256"`
	} `json:"carves"`
	Isolation   map[string]bool  `json:"isolation"`
	Caps        map[string]int64 `json:"caps"`
	Limitations []string         `json:"limitations"`
	Input       inputRecord      `json:"input"`
	Artifact    struct {
		Path   string `json:"path"`
		SHA256 string `json:"sha256"`
	} `json:"isolation_artifact"`
}

func (w *world) report(dir string) report {
	w.t.Helper()
	b, err := os.ReadFile(w.path(dir + "/" + reportName))
	if err != nil {
		w.t.Fatal(err)
	}
	var r report
	if err := json.Unmarshal(b, &r); err != nil {
		w.t.Fatal(err)
	}
	return r
}

func TestCarveIsDeterministicAndTruthful(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	w.mustCarve(in, w.path("a"))
	w.mustCarve(in, w.path("b"))

	for _, name := range []string{reportName, "carves/00000004-uimage.bin"} {
		a, _ := os.ReadFile(w.path("a/" + name))
		b, _ := os.ReadFile(w.path("b/" + name))
		if len(a) == 0 || !bytes.Equal(a, b) {
			t.Errorf("%s differs between two carves of the same input", name)
		}
	}
	r := w.report("a")
	if r.Schema != "firmware-carve.v1" || len(r.Carves) != 2 || r.Carves[0].Kind != "uimage" || r.Carves[1].Kind != "squashfs-v4-le" {
		t.Fatalf("carves = %+v", r)
	}
	wantIso := map[string]bool{"bubblewrap": true, "network_access": false, "payload_execution": false, "static_only": true, "vm_boundary": false}
	for k, v := range wantIso {
		if got, ok := r.Isolation[k]; !ok || got != v {
			t.Errorf("isolation[%s] = %v (present %v), want %v", k, got, ok, v)
		}
	}
	if !strings.Contains(r.Limitations[0], "disposable VM") || r.Caps["max_carves"] != 16 || r.Caps["max_files"] != 17 {
		t.Errorf("limitations/caps = %v / %v", r.Limitations, r.Caps)
	}
	if r.Artifact.Path != "/usr/bin/bwrap" || r.Input.Size != int64(len(firmwareImage())) {
		t.Errorf("artifact/input = %+v / %+v", r.Artifact, r.Input)
	}
	if got := w.files("a"); strings.Join(got, ",") != "carves/00000004-uimage.bin,carves/00000056-squashfs-v4-le.bin,"+reportName {
		t.Errorf("tree = %v", got)
	}
	filepath.WalkDir(w.path("a"), func(p string, d os.DirEntry, _ error) error {
		fi, _ := os.Lstat(p)
		want := os.FileMode(0o400)
		if fi.IsDir() {
			want = 0o700
		}
		if fi.Mode()&os.ModeSymlink != 0 || fi.Mode().Perm() != want {
			t.Errorf("%s mode %v, want %v and no symlink", p, fi.Mode(), want)
		}
		return nil
	})
	for _, c := range r.Carves {
		data, err := os.ReadFile(w.path("a/" + c.Path))
		sum := sha256.Sum256(data)
		if err != nil || int64(len(data)) != c.Size || "sha256:"+hex.EncodeToString(sum[:]) != c.SHA256 {
			t.Errorf("carve %s does not match its record", c.Path)
		}
	}
	if w.exists(".a.stage") || w.exists(".b.stage") {
		t.Error("a stage directory outlived a successful carve")
	}
	data, _ := os.ReadFile(w.path("firmware.bin"))
	if want := data[uimageAt:squashAt]; !bytes.Contains(want, []byte(uimagePayload)) {
		t.Fatal("fixture offsets drifted")
	}
}

func TestInvalidCRCRangeAndUnsupportedInputsFailClosed(t *testing.T) {
	w := newWorld(t)
	image := firmwareImage()

	badCRC := append([]byte(nil), image...)
	badCRC[72] ^= 0xff // a payload byte: the uImage payload CRC no longer matches
	w.mustCarve(w.write("bad-crc.bin", badCRC), w.path("crc"))
	if got := w.files("crc/carves"); len(got) != 1 || !strings.HasSuffix(got[0], "squashfs-v4-le.bin") {
		t.Errorf("bad CRC: carves = %v, want only the SquashFS", got)
	}

	badRange := append([]byte(nil), image...)
	put64(badRange[squashAt+40:], uint64(len(badRange)+1)) // bytes_used beyond the input
	w.mustCarve(w.write("bad-range.bin", badRange), w.path("range"))
	if got := w.files("range/carves"); len(got) != 1 || !strings.HasSuffix(got[0], "uimage.bin") {
		t.Errorf("bad range: carves = %v, want only the uImage", got)
	}

	if code := w.carve(w.write("unsupported", []byte("unsupported")), w.path("unsupported-out")); code != 2 {
		t.Fatalf("unsupported input: exit %d, want 2", code)
	}
	want := "firmware-carve: isolated worker failed: firmware-carve: no validated supported image found\n"
	if w.err.String() != want || w.exists("unsupported-out") || w.exists(".unsupported-out.stage") {
		t.Errorf("stderr %q, output present %v", w.err.String(), w.exists("unsupported-out"))
	}
}

func put64(b []byte, v uint64) {
	for i := 0; i < 8; i++ {
		b[i] = byte(v >> (8 * i))
	}
}

func TestCapsFailWithoutPublication(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	cases := []struct {
		name  string
		extra []string
		want  string
	}{
		{"input", []string{"--max-input-bytes", "4"}, "firmware-carve: input exceeds max-input-bytes\n"},
		{"count", []string{"--max-carves", "1"}, "candidate count exceeds output caps"},
		{"bytes", []string{"--max-output-bytes", "64"}, "carved bytes exceed max-output-bytes"},
		{"files", []string{"--max-files", "2"}, "candidate count exceeds output caps"},
		{"zero", []string{"--max-processes", "0"}, "firmware-carve: caps must be positive\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if code := w.carve(in, w.path(tc.name), tc.extra...); code != 2 {
				t.Fatalf("exit %d, want 2 (stderr %q)", code, w.err.String())
			}
			if !strings.Contains(w.err.String(), tc.want) {
				t.Errorf("stderr %q lacks %q", w.err.String(), tc.want)
			}
			if w.exists(tc.name) || w.exists("."+tc.name+".stage") {
				t.Error("a failed carve left an output or a stage behind")
			}
		})
	}
}

func TestPathSafetyFailsClosed(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	if err := os.Symlink(in, w.path("link.bin")); err != nil {
		t.Fatal(err)
	}
	if err := mkfifo(w.path("device")); err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{"not-file", "unsafe", ".occupied.stage"} {
		if err := os.Mkdir(w.path(d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(w.path("unsafe"), 0o777); err != nil {
		t.Fatal(err)
	}
	w.write(".occupied.stage/sentinel", []byte("keep"))
	w.mustCarve(in, w.path("exists"))
	if err := os.Symlink(w.root, w.root+"-parent-link"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(w.root + "-parent-link") })

	cases := []struct{ name, input, out, want string }{
		{"symlink input", w.path("link.bin"), w.path("link-out"), "input must be a regular non-symlink file"},
		{"fifo input", w.path("device"), w.path("device-out"), "input is not a regular file"},
		{"directory input", w.path("not-file"), w.path("type-out"), "input is not a regular file"},
		{"occupied stage", in, w.path("occupied"), "File exists"},
		{"existing output", in, w.path("exists"), "output must be a new canonical path in a private owned directory"},
		{"writable parent", in, w.path("unsafe/out"), "output must be a new canonical path in a private owned directory"},
		{"linked parent", in, w.root + "-parent-link/out", "output parent links are not allowed"},
		{"dotdot", in, w.root + "/x/../y", "output must be a new canonical path"},
		{"backslash", in, w.path("a\\b"), "output must be a new canonical path"},
		{"missing parent", in, w.path("nope/out"), "No such file or directory"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if code := w.carve(tc.input, tc.out); code != 2 {
				t.Fatalf("exit %d, want 2 (stderr %q)", code, w.err.String())
			}
			if !strings.Contains(w.err.String(), tc.want) {
				t.Errorf("stderr %q lacks %q", w.err.String(), tc.want)
			}
		})
	}
	if b, err := os.ReadFile(w.path(".occupied.stage/sentinel")); err != nil || string(b) != "keep" {
		t.Error("the foreign stage directory was not preserved")
	}
}

func TestForeignFilesystemIsRefused(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	w.d.mountinfo = func() (string, error) { return "1 0 0:1 / / rw - drvfs C:\\ rw\n", nil }
	if code := w.carve(in, w.path("out")); code != 2 || !strings.Contains(w.err.String(), "output must reside on a Linux-private filesystem") {
		t.Errorf("exit %d stderr %q", code, w.err.String())
	}
}

func TestExternalHardlinkFailsClosedWithoutPublication(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	inner := w.d.launch
	w.d.launch = func(sp launchSpec) error {
		if err := inner(sp); err != nil {
			return err
		}
		return os.Link(filepath.Join(sp.dir, "carves/00000004-uimage.bin"), w.path("external-hardlink"))
	}
	if code := w.carve(in, w.path("out")); code != 2 || !strings.Contains(w.err.String(), "hardlink") {
		t.Fatalf("exit %d stderr %q", code, w.err.String())
	}
	if w.exists("out") || w.exists(".out.stage") || !w.exists("external-hardlink") {
		t.Error("expected no output, no stage, and the external link untouched")
	}
}

func TestPostRenameSyncFailureAcknowledgesTheDestination(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	w.d.syncDir = func(string) error { return syscall.EIO }
	if code := w.carve(in, w.path("out")); code != 3 {
		t.Fatalf("exit %d, want 3 (stderr %q)", code, w.err.String())
	}
	want := "DEGRADED: firmware-carve: published with uncertain durability: output exists at " + w.path("out") + ", but parent-directory sync failed\n"
	if w.err.String() != want {
		t.Errorf("stderr %q, want %q", w.err.String(), want)
	}
	if !w.exists("out/"+reportName) || w.exists(".out.stage") {
		t.Error("the published output must stay and the stage must be gone")
	}
	if code := w.carve(in, w.path("out")); code != 2 {
		t.Errorf("a retry over the published output exits %d, want 2 (no replace)", code)
	}
}

func TestWorkerIsLaunchedUnderTheCapsInsideTheSandbox(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	var got launchSpec
	inner := w.d.launch
	w.d.launch = func(sp launchSpec) error { got = sp; return inner(sp) }
	w.mustCarve(in, w.path("out"), "--timeout-seconds", "7", "--max-processes", "3", "--max-memory-bytes", "134217728")
	if got.timeout != 7*time.Second || got.maxProcs != 3 || got.memory != 134217728+runtimeAddressSpace || got.self != "/rsdd" {
		t.Errorf("launch spec = %+v", got)
	}
	if got.dir != w.path(".out.stage") && !strings.HasSuffix(got.dir, ".out.stage") {
		t.Errorf("worker directory = %q, want the stage", got.dir)
	}
	line := strings.Join(got.argv, " ")
	for _, want := range []string{
		"/usr/bin/bwrap --die-with-parent --new-session --unshare-net --unshare-pid --cap-drop ALL --ro-bind / / --tmpfs /tmp",
		"--bind " + got.dir + " /tmp/work --proc /proc --dev /dev --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8",
		"-- /rsdd corroborate carve --worker --input /tmp/work/input.bin --output /tmp/work/output --stage /tmp/work --input-record",
		"--max-input-bytes 1073741824 --max-output-bytes 1073741824 --max-carves 16 --max-files 17 --timeout-seconds 7 --max-processes 3 --max-memory-bytes 134217728",
	} {
		if !strings.Contains(line, want) {
			t.Errorf("sandbox command lacks %q:\n%s", want, line)
		}
	}
	if r := w.report("out"); r.Caps["max_memory_bytes"] != 134217728 {
		t.Errorf("the report must record the cap as given, got %v", r.Caps)
	}
}

func TestRootExecutionFailsClosed(t *testing.T) {
	w := newWorld(t)
	w.d.creds = func() adapter.Creds { return adapter.Creds{UID: 0, EUID: 0} }
	for _, extra := range [][]string{nil, {"--worker", "--stage", "/tmp", "--input-record", "{}", "--bwrap-path", "/usr/bin/bwrap", "--bwrap-sha256", "sha256:abc"}} {
		if code := w.carve("x", "y", extra...); code != 2 || !strings.Contains(w.err.String(), "root or set-id") {
			t.Errorf("args %v: exit %d stderr %q", extra, code, w.err.String())
		}
	}
}

func TestWorkerRefusesAStagedInputThatIsNotWhatTheParentMeasured(t *testing.T) {
	w := newWorld(t)
	stage := w.path("stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		t.Fatal(err)
	}
	data := firmwareImage()
	staged := filepath.Join(stage, "input.bin")
	if err := os.WriteFile(staged, data, 0o400); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	record := func(size int, digest string) string {
		b, _ := json.Marshal(map[string]any{"path": "/x", "size": size, "sha256": digest})
		return string(b)
	}
	good := "sha256:" + hex.EncodeToString(sum[:])
	run := func(rec string) (int, string) {
		var stderr bytes.Buffer
		code := execute([]string{"--worker", "--input", "i", "--output", "o", "--stage", stage, "--input-record", rec,
			"--bwrap-path", "/usr/bin/bwrap", "--bwrap-sha256", "sha256:" + strings.Repeat("0", 64)}, cli.Stdio{Out: &bytes.Buffer{}, Err: &stderr}, w.d)
		return code, stderr.String()
	}
	if code, msg := run(record(len(data), "sha256:"+strings.Repeat("0", 64))); code != 2 || !strings.Contains(msg, "staged input identity mismatch") {
		t.Errorf("wrong digest: exit %d %q", code, msg)
	}
	if err := os.Chmod(staged, 0o644); err != nil {
		t.Fatal(err)
	}
	if code, msg := run(record(len(data), good)); code != 2 || !strings.Contains(msg, "staged input type, owner, or mode changed") {
		t.Errorf("writable staged input: exit %d %q", code, msg)
	}
	if err := os.Chmod(staged, 0o400); err != nil {
		t.Fatal(err)
	}
	if code, msg := run(record(len(data), good)); code != 0 || msg != "" {
		t.Errorf("honest staged input: exit %d %q", code, msg)
	}
	if err := os.Remove(staged); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(staged, nil, 0o400); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(filepath.Join(stage, "carves")); err != nil {
		t.Fatal(err)
	}
	if code, msg := run(record(0, "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")); code != 2 || !strings.Contains(msg, "cannot mmap an empty file") {
		t.Errorf("empty staged input: exit %d %q", code, msg)
	}
}

func TestUsage(t *testing.T) {
	w := newWorld(t)
	for _, tc := range []struct {
		args []string
		code int
		out  string
		err  string
	}{
		{[]string{"-h"}, 0, "usage: rsdd corroborate carve", ""},
		{[]string{"--output", "x"}, 2, "", "the following arguments are required: --input"},
		{nil, 2, "", "the following arguments are required: --input, --output"},
		{[]string{"--input", "a", "--output", "b", "stray"}, 2, "", "unrecognized arguments: stray"},
		{[]string{"--input", "a", "--output", "b", "--max-carves", "many"}, 2, "", "invalid value"},
	} {
		var out, errw bytes.Buffer
		code := execute(tc.args, cli.Stdio{Out: &out, Err: &errw}, w.d)
		if code != tc.code || !strings.Contains(out.String(), tc.out) || !strings.Contains(errw.String(), tc.err) {
			t.Errorf("%v: exit %d, stdout %q, stderr %q", tc.args, code, out.String(), errw.String())
		}
	}
}
