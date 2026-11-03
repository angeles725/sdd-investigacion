//go:build linux

package formats

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// pub is a fresh output parent: owned, not group/world writable, on the test filesystem.
func pub(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	if err := os.Chmod(d, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

func fixture(t *testing.T, name string) string {
	t.Helper()
	all := metaFixtures()
	for k, v := range storedFixtures() {
		if !strings.HasSuffix(k, ".zip") {
			k += ".zip"
		}
		if _, dup := all[k]; !dup {
			all[k] = v
		}
	}
	data, ok := all[name]
	if !ok {
		t.Fatalf("no fixture %q", name)
	}
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, data, 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func zipReadJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func TestZipMetadataReport(t *testing.T) {
	t.Parallel()
	out := filepath.Join(pub(t), "out")
	code, stdout, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, fixture(t, "mixed.zip"), out)...)
	if code != 0 || stdout != "" || stderr != "" {
		t.Fatalf("exit %d stdout %q stderr %q", code, stdout, stderr)
	}
	rep := zipReadJSON(t, filepath.Join(out, "zip-metadata.v1.json"))
	entries := rep["entries"].([]any)
	if rep["schema"] != "zip-metadata.v1" || len(entries) != 7 || rep["payload_bytes_read"].(float64) != 0 {
		t.Fatalf("report header: %v", rep)
	}
	safety := func(i int, k string) bool { return entries[i].(map[string]any)["safety"].(map[string]any)[k].(bool) }
	e1 := entries[1].(map[string]any)
	if e1["encrypted"] != true || e1["method"].(float64) != 99 || !safety(1, "traversal") {
		t.Errorf("entry 1 = %v", e1)
	}
	if !safety(2, "backslash") || !safety(3, "absolute") || !safety(4, "duplicate") || !safety(5, "duplicate") || !safety(6, "nul") {
		t.Errorf("safety markers wrong: %v", entries)
	}
	if safety(0, "duplicate") || safety(0, "traversal") || safety(0, "absolute") || safety(0, "backslash") || safety(0, "nul") {
		t.Errorf("a clean name must carry no marker: %v", entries[0])
	}
	tree := readTree(t, out)
	if got := strings.Join(treeNames(tree), ","); got != "analysis-manifest.v1.json,input,input/central-directory.bin,stderr.txt,stdout.txt,zip-metadata.v1.json" {
		t.Errorf("tree = %s", got)
	}
	meta := tree["input/central-directory.bin"].data
	sum := sha256.Sum256([]byte(meta))
	if got := rep["input"].(map[string]any)["metadata_sha256"]; got != "sha256:"+hex.EncodeToString(sum[:]) {
		t.Errorf("metadata_sha256 = %v", got)
	}
	if strings.Contains(meta, "PAYLOAD-NOT-METADATA") || strings.Contains(meta, "SECRET") {
		t.Error("the staged metadata must not contain any payload")
	}
}

func TestZipMetadataDeterministic(t *testing.T) {
	t.Parallel()
	parent := pub(t)
	in := fixture(t, "mixed.zip")
	for _, n := range []string{"a", "b"} {
		if code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, in, filepath.Join(parent, n))...); code != 0 {
			t.Fatalf("%s: exit %d %s", n, code, stderr)
		}
	}
	a, _ := os.ReadFile(filepath.Join(parent, "a", "zip-metadata.v1.json"))
	b, _ := os.ReadFile(filepath.Join(parent, "b", "zip-metadata.v1.json"))
	if len(a) == 0 || string(a) != string(b) {
		t.Fatal("two runs over the same input must publish the same report")
	}
}

func TestZipRefusesPrivilegedExecution(t *testing.T) {
	for name, creds := range map[string][4]int{"root": {0, 0, 0, 0}, "setuid": {1000, 0, 1000, 1000}, "setgid": {1000, 1000, 1000, 5}, "uid differs": {1000, 1001, 1000, 1000}} {
		t.Run(name, func(t *testing.T) {
			old := zipCreds
			zipCreds = func() (int, int, int, int) { return creds[0], creds[1], creds[2], creds[3] }
			t.Cleanup(func() { zipCreds = old })
			for label, run := range map[string]func() (int, string, string){
				"metadata": func() (int, string, string) {
					return runGo(t, ZipMetadata, "/", metaArgs(t, "x", filepath.Join(pub(t), "o"))...)
				},
				"stored": func() (int, string, string) {
					return runGo(t, ZipStored, "/", storedArgs(t, "x", filepath.Join(pub(t), "o"))...)
				},
			} {
				code, _, stderr := run()
				if code != 2 || !strings.Contains(stderr, "root or set-id") {
					t.Errorf("%s: exit %d stderr %q", label, code, stderr)
				}
			}
		})
	}
	old := zipCreds
	zipCreds = func() (int, int, int, int) { return 1000, 1000, 1000, 1000 }
	t.Cleanup(func() { zipCreds = old })
	if err := zipRefusePrivileged(); err != nil {
		t.Errorf("an ordinary user must be accepted: %v", err)
	}
}

func TestZipMetadataRejectsInputChangedWhileReading(t *testing.T) {
	in := fixture(t, "mixed.zip")
	out := filepath.Join(pub(t), "out")
	zipAfterInventory = func() {
		st, _ := os.Stat(in)
		_ = os.Chtimes(in, time.Now(), st.ModTime().Add(time.Second))
	}
	t.Cleanup(func() { zipAfterInventory = nil })
	code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, in, out)...)
	if code != 2 || !strings.Contains(stderr, "input changed while reading metadata") {
		t.Fatalf("exit %d stderr %q", code, stderr)
	}
	assertNoLeftovers(t, filepath.Dir(out), "out")
}

func TestZipPathFailuresPublishNothing(t *testing.T) {
	t.Parallel()
	good := fixture(t, "good.zip")
	for _, c := range []struct {
		name string
		run  func(args []string) (int, string)
		args func(in, out string) []string
	}{
		{"metadata", func(a []string) (int, string) { c, _, e := runGo(t, ZipMetadata, "/", a...); return c, e }, func(in, out string) []string { return metaArgs(t, in, out) }},
		{"stored", func(a []string) (int, string) { c, _, e := runGo(t, ZipStored, "/", a...); return c, e }, func(in, out string) []string { return storedArgs(t, in, out) }},
	} {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			parent := pub(t)
			// a symlinked input
			link := filepath.Join(parent, "link.zip")
			if err := os.Symlink(good, link); err != nil {
				t.Fatal(err)
			}
			if code, _ := c.run(c.args(link, filepath.Join(parent, "link-out"))); code != 2 {
				t.Errorf("symlink input: exit %d", code)
			}
			assertNoLeftovers(t, parent, "link-out")
			// an existing destination and an occupied stage path are preserved
			if err := os.MkdirAll(filepath.Join(parent, "collision"), 0o700); err != nil {
				t.Fatal(err)
			}
			_ = os.WriteFile(filepath.Join(parent, "collision", "keep"), []byte("keep"), 0o600)
			_ = os.MkdirAll(filepath.Join(parent, ".occupied.stage"), 0o700)
			_ = os.WriteFile(filepath.Join(parent, ".occupied.stage", "keep"), []byte("stage"), 0o600)
			if code, _ := c.run(c.args(good, filepath.Join(parent, "collision"))); code != 2 {
				t.Errorf("existing destination: exit %d", code)
			}
			if code, _ := c.run(c.args(good, filepath.Join(parent, "occupied"))); code != 2 {
				t.Errorf("occupied stage: exit %d", code)
			}
			for _, keep := range []string{"collision/keep", ".occupied.stage/keep"} {
				if _, err := os.Stat(filepath.Join(parent, keep)); err != nil {
					t.Errorf("%s must be preserved: %v", keep, err)
				}
			}
			// a dangling symlink at the destination counts as existing
			if err := os.Symlink(filepath.Join(parent, "nowhere"), filepath.Join(parent, "dangling")); err != nil {
				t.Fatal(err)
			}
			if code, _ := c.run(c.args(good, filepath.Join(parent, "dangling"))); code != 2 {
				t.Errorf("dangling destination: exit %d", code)
			}
			// unsafe output names and parents
			for _, bad := range []string{filepath.Join(parent, "x", ".."), parent + "/.", filepath.Join(parent, "missing", "out")} {
				if code, _ := c.run(c.args(good, bad)); code != 2 {
					t.Errorf("output %q: exit %d", bad, code)
				}
			}
			real := pub(t)
			viaLink := filepath.Join(parent, "parentlink")
			if err := os.Symlink(real, viaLink); err != nil {
				t.Fatal(err)
			}
			code, stderr := c.run(c.args(good, filepath.Join(viaLink, "out")))
			if code != 2 || !strings.Contains(stderr, "output parent links are unsupported") {
				t.Errorf("symlinked parent: exit %d stderr %q", code, stderr)
			}
			open := pub(t)
			if err := os.Chmod(open, 0o775); err != nil {
				t.Fatal(err)
			}
			if code, _ := c.run(c.args(good, filepath.Join(open, "out"))); code != 2 {
				t.Errorf("group-writable parent: exit %d", code)
			}
			assertNoLeftovers(t, open, "out")
		})
	}
}

func TestZipRelativePathsResolveAgainstCwd(t *testing.T) {
	t.Parallel()
	parent := pub(t)
	data := metaFixtures()["empty.zip"]
	if err := os.WriteFile(filepath.Join(parent, "in.zip"), data, 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, stderr := runGo(t, ZipMetadata, parent, metaArgs(t, "in.zip", "rel-out")...); code != 0 {
		t.Fatalf("exit %d %s", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(parent, "rel-out", "zip-metadata.v1.json")); err != nil {
		t.Fatal(err)
	}
}

func TestZipStoredRelativePathsResolveAgainstCwd(t *testing.T) {
	t.Parallel()
	parent := pub(t)
	if err := os.WriteFile(filepath.Join(parent, "in.zip"), storedFixtures()["good.zip"], 0o600); err != nil {
		t.Fatal(err)
	}
	if code, _, stderr := runGo(t, ZipStored, parent, storedArgs(t, "in.zip", "rel-out")...); code != 0 {
		t.Fatalf("exit %d %s", code, stderr)
	}
	if b, err := os.ReadFile(filepath.Join(parent, "rel-out", "dir", "a.txt")); err != nil || string(b) != "alpha" {
		t.Fatalf("extracted file: %q %v", b, err)
	}
}

func TestZipUsageErrors(t *testing.T) {
	t.Parallel()
	for _, c := range []struct {
		name string
		args []string
		want string
	}{
		{"metadata no args", nil, "the following arguments are required: --input, --output, --manifest-cli"},
		{"metadata missing manifest", []string{"--input", "a", "--output", "b"}, "the following arguments are required: --manifest-cli"},
		{"metadata positional", []string{"--input", "a", "--output", "b", "--manifest-cli", "c", "extra"}, "unrecognized arguments: extra"},
		{"metadata bad int", []string{"--input", "a", "--output", "b", "--manifest-cli", "c", "--max-entries", "many"}, "invalid int value"},
		{"metadata unknown flag", []string{"--input", "a", "--output", "b", "--manifest-cli", "c", "--nope"}, "flag provided but not defined"},
	} {
		t.Run(c.name, func(t *testing.T) {
			code, out, stderr := runGo(t, ZipMetadata, "/", c.args...)
			if code != 2 || out != "" || !strings.Contains(stderr, c.want) {
				t.Errorf("exit %d stdout %q stderr %q", code, out, stderr)
			}
			code, out, stderr = runGo(t, ZipStored, "/", c.args...)
			if code != 2 || out != "" || !strings.Contains(stderr, c.want) {
				t.Errorf("stored: exit %d stdout %q stderr %q", code, out, stderr)
			}
		})
	}
	if code, _, stderr := runGo(t, ZipMetadata, "/", "-h"); code != 0 || !strings.Contains(stderr, "usage: rsdd formats zip-metadata") {
		t.Errorf("help: exit %d stderr %q", code, stderr)
	}
	if code, _, stderr := runGo(t, ZipStored, "/", "--help"); code != 0 || strings.Contains(stderr, "manifest-cli") {
		t.Errorf("help must exit 0 and hide --manifest-cli: exit %d stderr %q", code, stderr)
	}
}

func TestZipFailedManifestPublishesNothing(t *testing.T) {
	t.Parallel()
	parent := pub(t)
	for name, run := range map[string]func(args []string) int{
		"metadata": func(a []string) int { c, _, _ := runGo(t, ZipMetadata, "/", a...); return c },
		"stored":   func(a []string) int { c, _, _ := runGo(t, ZipStored, "/", a...); return c },
	} {
		in := fixture(t, "good.zip")
		args := []string{"--input", in, "--output", filepath.Join(parent, name), "--manifest-cli", "/nonexistent/analysis_manifest.py"}
		if code := run(args); code != 2 {
			t.Errorf("%s: exit %d", name, code)
		}
		assertNoLeftovers(t, parent, name)
	}
}

func TestZipUncertainDurabilityAfterPublication(t *testing.T) {
	forced := errors.New("forced sync failure")
	old := zipSyncDir
	t.Cleanup(func() { zipSyncDir = old })

	// The post-rename sync is the only call that fails.
	zipSyncDir = func(string) error { return forced }
	parent := pub(t)
	in := fixture(t, "good.zip")
	code, _, stderr := runGo(t, ZipStored, "/", storedArgs(t, in, filepath.Join(parent, "out"))...)
	if code != 3 {
		t.Fatalf("stored: exit %d stderr %q, want 3", code, stderr)
	}
	if !strings.Contains(stderr, "DEGRADED: zip-stored: published with uncertain durability") || strings.Count(stderr, "DEGRADED:") != 1 {
		t.Errorf("stderr = %q", stderr)
	}
	if _, err := os.Stat(filepath.Join(parent, "out", "zip-stored.v1.json")); err != nil {
		t.Errorf("the destination must exist after the rename: %v", err)
	}
	if _, err := os.Stat(filepath.Join(parent, ".out.stage")); err == nil {
		t.Error("the stage name must be gone after the rename")
	}
	// A retry is no-replace.
	if code, _, _ := runGo(t, ZipStored, "/", storedArgs(t, in, filepath.Join(parent, "out"))...); code != 2 {
		t.Errorf("retry over the published destination: exit %d", code)
	}

	// zip-metadata reports the same situation as an ordinary failure (exit 2) with the destination in place.
	parent = pub(t)
	code, _, stderr = runGo(t, ZipMetadata, "/", metaArgs(t, fixture(t, "mixed.zip"), filepath.Join(parent, "out"))...)
	if code != 2 || !strings.Contains(stderr, "forced sync failure") {
		t.Errorf("metadata: exit %d stderr %q", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(parent, "out", "zip-metadata.v1.json")); err != nil {
		t.Errorf("metadata destination must exist: %v", err)
	}
}

func TestZipStoredExtraction(t *testing.T) {
	t.Parallel()
	out := filepath.Join(pub(t), "out")
	code, stdout, stderr := runGo(t, ZipStored, "/", storedArgs(t, fixture(t, "good.zip"), out)...)
	if code != 0 || stdout != "" || stderr != "" {
		t.Fatalf("exit %d stdout %q stderr %q", code, stdout, stderr)
	}
	tree := readTree(t, out)
	if got := strings.Join(treeNames(tree), ","); got != "analysis-manifest.v1.json,b.bin,dir,dir/a.txt,stderr.txt,stdout.txt,zip-stored.v1.json" {
		t.Fatalf("tree = %s", got)
	}
	if tree["dir/a.txt"].data != "alpha" || tree["b.bin"].data != "\x00\x01" {
		t.Errorf("payloads: %q %q", tree["dir/a.txt"].data, tree["b.bin"].data)
	}
	for name, e := range tree {
		want := os.FileMode(0o400)
		if name == "dir" {
			want = os.ModeDir | 0o700
		}
		if e.mode != want {
			t.Errorf("%s mode = %v, want %v", name, e.mode, want)
		}
	}
	rep := zipReadJSON(t, filepath.Join(out, "zip-stored.v1.json"))
	entries := rep["entries"].([]any)
	if rep["schema"] != "zip-stored.v1" || len(entries) != 3 || rep["total_extracted_bytes"].(float64) != 7 {
		t.Fatalf("report: %v", rep)
	}
	sum := sha256.Sum256([]byte("alpha"))
	a := entries[1].(map[string]any)
	if a["path"] != "dir/a.txt" || a["sha256"] != "sha256:"+hex.EncodeToString(sum[:]) || a["type"] != "file" || a["size"].(float64) != 5 {
		t.Errorf("entry a.txt = %v", a)
	}
	if d := entries[0].(map[string]any); d["type"] != "directory" || d["sha256"] != nil {
		t.Errorf("directory entry = %v", d)
	}
	if _, staged := tree["archive.zip"]; staged {
		t.Error("the staged archive must be removed")
	}
	verifyInProcess(t, out)
}

func TestZipStoredDeterministic(t *testing.T) {
	t.Parallel()
	parent := pub(t)
	in := fixture(t, "good.zip")
	for _, n := range []string{"a", "b"} {
		if code, _, stderr := runGo(t, ZipStored, "/", storedArgs(t, in, filepath.Join(parent, n))...); code != 0 {
			t.Fatalf("%s: exit %d %s", n, code, stderr)
		}
	}
	a, _ := os.ReadFile(filepath.Join(parent, "a", "zip-stored.v1.json"))
	b, _ := os.ReadFile(filepath.Join(parent, "b", "zip-stored.v1.json"))
	if len(a) == 0 || string(a) != string(b) {
		t.Fatal("two runs over the same input must publish the same report")
	}
}

func TestZipStoredStagingGuards(t *testing.T) {
	t.Parallel()
	stage, err := os.OpenRoot(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer stage.Close()
	in := fixture(t, "good.zip")
	rec, err := stageInput(in, stage, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(in)
	sum := sha256.Sum256(data)
	if rec.size != int64(len(data)) || rec.sha256 != "sha256:"+hex.EncodeToString(sum[:]) {
		t.Errorf("staged record = %+v", rec)
	}
	staged, _ := stage.Open("archive.zip")
	st, _ := staged.Stat()
	staged.Close()
	if st.Mode().Perm() != 0o400 || st.Size() != int64(len(data)) {
		t.Errorf("staged archive mode %v size %d", st.Mode().Perm(), st.Size())
	}
	if _, err := stageInput(in, stage, 1<<20); err == nil {
		t.Error("a second staging over an existing archive.zip must fail")
	}
	// Exactly at the limit passes, one byte less fails.
	other, _ := os.OpenRoot(t.TempDir())
	defer other.Close()
	if _, err := stageInput(in, other, int64(len(data))-1); err == nil || !strings.Contains(err.Error(), "max-input-bytes") {
		t.Errorf("limit-1: %v", err)
	}
	third, _ := os.OpenRoot(t.TempDir())
	defer third.Close()
	if _, err := stageInput(in, third, int64(len(data))); err != nil {
		t.Errorf("limit exactly the size must pass: %v", err)
	}
}

func TestZipValidateTree(t *testing.T) {
	build := func(t *testing.T) string {
		stage := t.TempDir()
		if err := os.Chmod(stage, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(filepath.Join(stage, "d"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, "d", "f"), []byte("x"), 0o400); err != nil {
			t.Fatal(err)
		}
		return stage
	}
	files, dirs := map[string]bool{"d/f": true}, map[string]bool{"d": true}
	if err := zipValidateTree(build(t), files, dirs); err != nil {
		t.Fatalf("a correct tree must validate: %v", err)
	}
	if err := zipValidateTree(build(t), files, nil); err != nil {
		t.Fatalf("a nil directory set leaves directories unchecked: %v", err)
	}
	for name, mutate := range map[string]func(string){
		"loose file mode": func(s string) { _ = os.Chmod(filepath.Join(s, "d", "f"), 0o600) },
		"loose dir mode":  func(s string) { _ = os.Chmod(filepath.Join(s, "d"), 0o755) },
		"extra file":      func(s string) { _ = os.WriteFile(filepath.Join(s, "extra"), nil, 0o400) },
		"symlink":         func(s string) { _ = os.Symlink("d/f", filepath.Join(s, "ln")) },
		"hardlink": func(s string) {
			_ = os.Link(filepath.Join(s, "d", "f"), filepath.Join(s, "..", filepath.Base(s)+"-twin"))
		},
		"fifo":         func(s string) { _ = syscall.Mkfifo(filepath.Join(s, "p"), 0o400) },
		"extra dir":    func(s string) { _ = os.Mkdir(filepath.Join(s, "e"), 0o700) },
		"missing file": func(s string) { _ = os.Remove(filepath.Join(s, "d", "f")) },
	} {
		t.Run(name, func(t *testing.T) {
			s := build(t)
			mutate(s)
			err := zipValidateTree(s, files, dirs)
			if err == nil {
				t.Fatal("the tree must be rejected")
			}
			var ze *ZipError
			if !errors.As(err, &ze) {
				t.Fatalf("want a ZipError, got %T %v", err, err)
			}
			t.Cleanup(func() { _ = os.Remove(filepath.Join(s, "..", filepath.Base(s)+"-twin")) })
		})
	}
	other := build(t)
	old := zipGetuid
	zipGetuid = func() int { return os.Getuid() + 1 }
	t.Cleanup(func() { zipGetuid = old })
	if err := zipValidateTree(other, files, dirs); err == nil || !strings.Contains(err.Error(), "ownership") {
		t.Errorf("a tree owned by someone else must be rejected: %v", err)
	}
}

func TestZipFinalizeLocksModes(t *testing.T) {
	t.Parallel()
	// zipFinalize runs the manifest tool; the tool runs here with the real analysis_manifest.py.
	parent := pub(t)
	out := filepath.Join(parent, "out")
	if code, _, stderr := runGo(t, ZipMetadata, "/", metaArgs(t, fixture(t, "empty.zip"), out)...); code != 0 {
		t.Fatalf("exit %d %s", code, stderr)
	}
	for name, e := range readTree(t, out) {
		want := os.FileMode(0o400)
		if e.mode.IsDir() {
			want = os.ModeDir | 0o700
		}
		if e.mode != want {
			t.Errorf("%s mode = %v, want %v", name, e.mode, want)
		}
	}
	if _, err := os.Stat(filepath.Join(out, "manifest-spec.json")); err == nil {
		t.Error("the manifest spec must be removed after create")
	}
}
