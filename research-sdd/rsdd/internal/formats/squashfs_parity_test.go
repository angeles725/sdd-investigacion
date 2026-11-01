//go:build linux && !nodiff

package formats

// The differential half of the squashfs tests: the frozen legacy script (testdata/squashfs/legacy) is the
// oracle and the real bwrap and unsquashfs run. They are the slow tests, so `make teeth` (-tags nodiff) leaves
// them out; the unit tests in squashfs_test.go carry the mutation kills.

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"
)

func needRealTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"bwrap", "unsquashfs"} {
		if _, err := exec.LookPath(tool); err != nil {
			skipOrFail(t, tool+" not installed")
		}
	}
	if err := exec.Command("bwrap", "--ro-bind", "/", "/", "true").Run(); err != nil {
		skipOrFail(t, "bubblewrap cannot create an unprivileged sandbox here: "+err.Error())
	}
}

// skipOrFail skips, or fails under RSDD_REQUIRE_BWRAP=1 (CI): a skipped sandbox test proves nothing.
func skipOrFail(t *testing.T, why string) {
	t.Helper()
	if os.Getenv("RSDD_REQUIRE_BWRAP") == "1" {
		t.Fatalf("required tool missing: %s", why)
	}
	t.Skip(why)
}

// ---------------------------------------------------------------- differential tests against the legacy script

type pyOp map[string]any

type pyOpRes struct {
	OK     bool            `json:"ok"`
	Value  json.RawMessage `json:"value"`
	Error  string          `json:"error"`
	RC     int             `json:"rc"`
	Stderr string          `json:"stderr"`
}

func oracleSqfs(t *testing.T, ops []pyOp) []pyOpRes {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	in, _ := json.Marshal(ops)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, "-I", abs(t, sqfsDriver), abs(t, sqfsLegacy), abs(t, toolbelt))
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle driver failed: %v\n%s", err, errb.String())
	}
	var rs []pyOpRes
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil || len(rs) != len(ops) {
		t.Fatalf("oracle output: %v (%d results for %d ops)\n%s", err, len(rs), len(ops), out.String())
	}
	return rs
}

func TestSquashfsParityFindOffset(t *testing.T) {
	base := sqfsSuperblock(t)
	rng := rand.New(rand.NewPCG(2417, 14))
	var ops []pyOp
	var datas [][]byte
	add := func(b []byte) {
		datas = append(datas, b)
		ops = append(ops, pyOp{"op": "find", "data_hex": hex.EncodeToString(b)})
	}
	add(base)
	add(base[:95])
	add(base[:96])
	add(append(bytes.Repeat([]byte{1}, 300), base...))
	add(append(append([]byte("hsqs"), make([]byte, 50)...), base...))
	for i := 0; i < 400; i++ {
		b := append([]byte(nil), base...)
		for k := 0; k <= rng.IntN(3); k++ {
			pos := rng.IntN(96)
			switch rng.IntN(4) {
			case 0:
				b[pos] = 0xff
			case 1:
				b[pos] = 0
			case 2:
				b[pos]++
			default:
				b[pos] = byte(rng.IntN(256))
			}
		}
		if rng.IntN(5) == 0 {
			b = append(bytes.Repeat([]byte{0xEE}, rng.IntN(200)), b...)
		}
		add(b)
	}
	accepted := 0
	results := oracleSqfs(t, ops)
	for i, b := range datas {
		off, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b)))
		r := results[i]
		switch {
		case r.OK && err != nil:
			t.Errorf("case %d: legacy found %s, port refused: %v", i, r.Value, err)
		case !r.OK && err == nil:
			t.Errorf("case %d: legacy refused (%s), port found %d", i, r.Error, off)
		case r.OK:
			accepted++
			if string(r.Value) != fmt.Sprint(off) {
				t.Errorf("case %d: offset legacy %s, port %d", i, r.Value, off)
			}
		case r.Error != err.Error():
			t.Errorf("case %d: message legacy %q, port %q", i, r.Error, err)
		}
	}
	if accepted < 50 || accepted > len(datas)-50 {
		t.Errorf("corpus accepted %d of %d: it must exercise both outcomes", accepted, len(datas))
	}
}

func entriesJSON(es []treeEntry) string {
	out := make([]map[string]any, len(es))
	for i, e := range es {
		m := map[string]any{"path": e.Path, "type": e.Type, "mode": e.Mode}
		if e.Type == "file" {
			m["size"], m["sha256"] = e.Size, e.SHA256
		}
		out[i] = m
	}
	b, _ := json.Marshal(out)
	return string(b)
}

func TestSquashfsParityWalkTree(t *testing.T) {
	type tcase struct {
		name    string
		build   func(r string)
		entries int
		bytes   int64
	}
	cases := []tcase{
		{"mixed", func(r string) {
			write(t, r+"/b.txt", "bee", 0o644)
			write(t, r+"/a/z.bin", "zed", 0o755)
			write(t, r+"/a/c/deep", "", 0o600)
			write(t, r+"/café/über", "u", 0o644)
			_ = os.MkdirAll(r+"/empty", 0o750)
		}, 100, 1000},
		{"empty root", func(r string) {}, 10, 10},
		{"file symlink", func(r string) { _ = os.Symlink("/etc/passwd", r+"/l") }, 10, 100},
		{"nested file symlink", func(r string) { _ = os.MkdirAll(r+"/d", 0o755); _ = os.Symlink("x", r+"/d/l") }, 10, 100},
		{"hardlink", func(r string) { write(t, r+"/a", "x", 0o644); _ = os.Link(r+"/a", r+"/b") }, 10, 100},
		{"fifo", func(r string) { _ = syscall.Mkfifo(r+"/p", 0o600) }, 10, 100},
		{"entries cap files", func(r string) { write(t, r+"/a", "", 0o644); write(t, r+"/b", "", 0o644) }, 1, 100},
		{"entries cap dirs", func(r string) { _ = os.MkdirAll(r+"/a/b", 0o755) }, 1, 100},
		{"entries exactly at cap", func(r string) { write(t, r+"/a", "", 0o644); _ = os.Mkdir(r+"/d", 0o755) }, 2, 100},
		{"bytes cap", func(r string) { write(t, r+"/a", "12345", 0o644); write(t, r+"/b", "12345", 0o644) }, 10, 9},
		{"bytes exactly at cap", func(r string) { write(t, r+"/a", "12345", 0o644); write(t, r+"/b", "1234", 0o644) }, 10, 9},
	}
	var ops []pyOp
	var roots []string
	for _, c := range cases {
		root := mkTree(t, c.build)
		roots = append(roots, root)
		ops = append(ops, pyOp{"op": "walk", "root": root, "max_entries": c.entries, "max_bytes": c.bytes})
	}
	results := oracleSqfs(t, ops)
	for i, c := range cases {
		got, err := walkTree(roots[i], c.entries, c.bytes)
		r := results[i]
		switch {
		case r.OK && err != nil:
			t.Errorf("%s: legacy ok, port: %v", c.name, err)
		case !r.OK && err == nil:
			t.Errorf("%s: legacy refused (%s), port ok", c.name, r.Error)
		case !r.OK:
			if r.Error != err.Error() {
				t.Errorf("%s: message legacy %q, port %q", c.name, r.Error, err)
			}
		default:
			var want []map[string]any
			_ = json.Unmarshal(r.Value, &want)
			wb, _ := json.Marshal(want)
			if string(wb) != entriesJSON(got) {
				t.Errorf("%s: entries differ\n legacy %s\n port   %s", c.name, wb, entriesJSON(got))
			}
		}
	}
}

func TestSquashfsParityValidateClosed(t *testing.T) {
	build := func() string {
		stage := t.TempDir()
		for _, d := range []string{"extracted", "extracted/sub"} {
			_ = os.Mkdir(filepath.Join(stage, d), 0o700)
		}
		for _, f := range []string{"report.json", "extracted/a", "extracted/sub/b"} {
			write(t, filepath.Join(stage, f), "x", 0o400)
		}
		return stage
	}
	files := []string{"report.json", "extracted/a", "extracted/sub/b"}
	dirs := []string{"extracted", "extracted/sub"}
	muts := map[string]func(s string){
		"closed":       func(s string) {},
		"file mode":    func(s string) { _ = os.Chmod(s+"/extracted/a", 0o600) },
		"dir mode":     func(s string) { _ = os.Chmod(s+"/extracted/sub", 0o755) },
		"extra file":   func(s string) { write(t, s+"/extra", "x", 0o400) },
		"extra dir":    func(s string) { _ = os.Mkdir(s+"/extradir", 0o700) },
		"missing file": func(s string) { _ = os.Remove(s + "/extracted/a") },
		"dir as file":  func(s string) { _ = os.Remove(s + "/extracted/a"); _ = os.Mkdir(s+"/extracted/a", 0o700) },
		"symlink":      func(s string) { _ = os.Symlink("report.json", s+"/lnk") },
		"fifo":         func(s string) { _ = syscall.Mkfifo(s+"/pipe", 0o400) },
	}
	var names []string
	for n := range muts {
		names = append(names, n)
	}
	sort.Strings(names)
	var ops []pyOp
	var stages []string
	for _, n := range names {
		s := build()
		muts[n](s)
		stages = append(stages, s)
		ops = append(ops, pyOp{"op": "closed", "stage": s, "files": files, "dirs": dirs})
	}
	results := oracleSqfs(t, ops)
	toSet := func(l []string) map[string]bool {
		m := map[string]bool{}
		for _, x := range l {
			m[x] = true
		}
		return m
	}
	for i, n := range names {
		err := validateClosed(stages[i], toSet(files), toSet(dirs))
		r := results[i]
		switch {
		case r.OK && err != nil:
			t.Errorf("%s: legacy ok, port: %v", n, err)
		case !r.OK && err == nil:
			t.Errorf("%s: legacy refused (%s), port ok", n, r.Error)
		case !r.OK && r.Error != err.Error():
			t.Errorf("%s: message legacy %q, port %q", n, r.Error, err)
		}
	}
}

// normManifest drops what is allowed to differ between the two implementations: the tool identity (the legacy
// launcher is python + script, the port's is the rsdd binary), argv, the run block and the identity hash.
func normManifest(m map[string]any) map[string]any {
	for _, k := range []string{"identity", "tool", "argv", "run"} {
		delete(m, k)
	}
	return m
}

// TestSquashfsParityEndToEnd runs the legacy script and the port on the same inputs, with the real bwrap and
// unsquashfs, and compares the exit code, the stderr text and the whole published tree.
func TestSquashfsParityEndToEnd(t *testing.T) {
	needRealTools(t)
	good := abs(t, sqfsData+"good.sqfs")
	raw, _ := os.ReadFile(good)
	scratch := t.TempDir()
	prefixed := filepath.Join(scratch, "firmware.bin")
	if err := os.WriteFile(prefixed, append(bytes.Repeat([]byte{0xAA}, 4096), raw...), 0o600); err != nil {
		t.Fatal(err)
	}
	blob := filepath.Join(scratch, "blob.bin")
	_ = os.WriteFile(blob, []byte("this is not a squashfs image"), 0o600)
	type pcase struct {
		name  string
		input string
		extra []string
	}
	cases := []pcase{
		{"good", good, nil},
		{"unicode names", abs(t, sqfsData+"uni.sqfs"), nil},
		{"embedded at offset 4096", prefixed, nil},
		{"symlink to a file", abs(t, sqfsData+"sym.sqfs"), nil},
		{"hardlinked files", abs(t, sqfsData+"hard.sqfs"), nil},
		{"size bomb", abs(t, sqfsData+"bomb.sqfs"), []string{"--max-extracted-bytes", "4096"}},
		{"entries cap", good, []string{"--max-entries", "1"}},
		{"bytes cap of one", good, []string{"--max-extracted-bytes", "1"}},
		{"not a squashfs", blob, nil},
		{"absent input", filepath.Join(scratch, "absent"), nil},
		{"timeout cap zero", good, []string{"--timeout-seconds", "0"}},
		{"input cap", good, []string{"--max-input-bytes", "100"}},
	}
	var ops []pyOp
	pyParents := make([]string, len(cases))
	for i, c := range cases {
		pyParents[i] = t.TempDir()
		argv := append([]string{"--input", c.input, "--output", filepath.Join(pyParents[i], "out"), "--manifest-cli", manifestCLI(t)}, c.extra...)
		ops = append(ops, pyOp{"op": "cli", "argv": argv})
	}
	results := oracleSqfs(t, ops)
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			goParent := t.TempDir()
			goOut := filepath.Join(goParent, "out")
			rc, _, stderr := runSqfs(t, goParent, sqfsArgs(c.input, goOut, append([]string{"--manifest-cli", manifestCLI(t)}, c.extra...)...)...)
			py := results[i]
			if rc != py.RC {
				t.Errorf("exit go %d, legacy %d\n go: %q\n py: %q", rc, py.RC, stderr, py.Stderr)
			}
			if want := strings.ReplaceAll(py.Stderr, pyParents[i], goParent); stderr != want {
				t.Errorf("stderr go %q, legacy %q", stderr, want)
			}
			pyOut := filepath.Join(pyParents[i], "out")
			mustNotExist(t, filepath.Join(goParent, ".out.stage"))
			_, pyErr := os.Stat(pyOut)
			_, goErr := os.Stat(goOut)
			if (pyErr == nil) != (goErr == nil) {
				t.Fatalf("published: legacy %v, port %v", pyErr == nil, goErr == nil)
			}
			if pyErr != nil {
				return
			}
			g, p := snapshot(t, goOut), snapshot(t, pyOut)
			if gm, pm := g["analysis-manifest.v1.json"], p["analysis-manifest.v1.json"]; gm.Mode != pm.Mode || gm.Type != pm.Type {
				t.Errorf("manifest file: go %+v, legacy %+v", gm, pm)
			}
			delete(g, "analysis-manifest.v1.json") // its content is compared field by field below
			delete(p, "analysis-manifest.v1.json")
			if fmt.Sprint(g) != fmt.Sprint(p) {
				t.Errorf("published trees differ\n go %v\n py %v", g, p)
			}
			gm := normManifest(readJSON(t, filepath.Join(goOut, "analysis-manifest.v1.json")))
			pm := normManifest(readJSON(t, filepath.Join(pyOut, "analysis-manifest.v1.json")))
			if fmt.Sprint(gm) != fmt.Sprint(pm) {
				t.Errorf("manifests differ (ignoring tool/argv/run/identity)\n go %v\n py %v", gm, pm)
			}
			verifyManifest(t, goOut)
		})
	}
}

// TestSquashfsDirectorySymlinkIsRefused is the one declared divergence from the legacy script: the legacy
// os.walk puts a symlink to a directory in dirnames, so walk_tree never sees it and the refusal came from a
// later chmod through the link (a Python-version-dependent "Operation not permitted"). The port refuses it
// where it first appears, with the same message as any other symlink.
func TestSquashfsDirectorySymlinkIsRefused(t *testing.T) {
	needRealTools(t)
	rc, stderr, parent, out := extract(t, abs(t, sqfsData+"dirsym.sqfs"))
	if rc != 2 || stderr != "squashfs-extract: symlink in extracted tree (rejected): somedir\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
}

func TestSquashfsRealToolsRefusals(t *testing.T) {
	needRealTools(t)
	for name, tc := range map[string]struct {
		image string
		extra []string
		want  string
	}{
		"symlink escape":    {"sym.sqfs", nil, "squashfs-extract: symlink in extracted tree (rejected): escape\n"},
		"hardlink":          {"hard.sqfs", nil, "squashfs-extract: hardlinked file in extracted tree: "},
		"size bomb":         {"bomb.sqfs", []string{"--max-extracted-bytes", "4096"}, "squashfs-extract: unsquashfs failed"},
		"max-entries":       {"good.sqfs", []string{"--max-entries", "1"}, "squashfs-extract: entries exceed max-entries (1)\n"},
		"max-extracted one": {"good.sqfs", []string{"--max-extracted-bytes", "1"}, "squashfs-extract: unsquashfs failed"},
	} {
		t.Run(name, func(t *testing.T) {
			rc, stderr, parent, out := extract(t, abs(t, sqfsData+tc.image), tc.extra...)
			if rc != 2 || !strings.HasPrefix(stderr, tc.want) {
				t.Errorf("rc = %d stderr = %q, want prefix %q", rc, stderr, tc.want)
			}
			mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
		})
	}
}
