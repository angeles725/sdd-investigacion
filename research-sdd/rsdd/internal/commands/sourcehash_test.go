package commands

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const fixtureDir = "testdata/source-hash"

func expectedFixtureHash(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixtureDir, "expected-hash.txt"))
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	if !strings.HasPrefix(s, "sha256:") || !strings.HasSuffix(s, "\n") || strings.Count(s, "\n") != 1 {
		t.Fatalf("expected-hash.txt must be one sha256:<hex> line, got %q", s)
	}
	return strings.TrimSuffix(s, "\n")
}

func TestFixtureHashMatchesIndependentPipeline(t *testing.T) {
	// The fixture lives under testdata/ yet must hash non-empty: the root's own
	// path is never matched, only paths relative to it.
	got, err := SourceHash(fixtureDir)
	if err != nil {
		t.Fatal(err)
	}
	if want := expectedFixtureHash(t); got != want {
		t.Errorf("SourceHash = %q, want %q (computed by the shell pipeline in the fixture README)", got, want)
	}
}

func TestFixtureSelectedFiles(t *testing.T) {
	fi, err := os.Lstat(filepath.Join(fixtureDir, "link.go"))
	if err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("fixture link.go must be a symlink (the symlink rule is untested otherwise): %v, %v", fi, err)
	}
	got, err := sourceFiles(os.DirFS(fixtureDir))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a.go", "embed/data.bin", "go.mod", "go.sum", "pkg/embed/x.txt", "sub/b.go", "vendor/v/lib.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("selected files = %v, want %v", got, want)
	}
}

func TestSelectionRules(t *testing.T) {
	f := func(s string) *fstest.MapFile { return &fstest.MapFile{Data: []byte(s)} }
	tests := []struct {
		name string
		fs   fstest.MapFS
		want []string
	}{
		{"go files, not tests", fstest.MapFS{"a.go": f("x"), "a_test.go": f("x"), "d/b.go": f("x"), "d/b_test.go": f("x")}, []string{"a.go", "d/b.go"}},
		{"go.mod and go.sum", fstest.MapFS{"go.mod": f("m"), "go.sum": f("s"), "a.go": f("x")}, []string{"a.go", "go.mod", "go.sum"}},
		{"go.sum optional", fstest.MapFS{"go.mod": f("m")}, []string{"go.mod"}},
		{"vendor tree", fstest.MapFS{"vendor/m/x.txt": f("v"), "vendor/modules.txt": f("v"), "a.go": f("x")}, []string{"a.go", "vendor/m/x.txt", "vendor/modules.txt"}},
		{"embed dirs at any depth", fstest.MapFS{"embed/a.bin": f("e"), "p/q/embed/b.bin": f("e"), "a.go": f("x")}, []string{"a.go", "embed/a.bin", "p/q/embed/b.bin"}},
		{"non-matching files", fstest.MapFS{"a.go": f("x"), "README.md": f("r"), "x/notes.txt": f("n"), "embedded/y.txt": f("n")}, []string{"a.go"}},
		{"testdata segment excludes everything", fstest.MapFS{"a.go": f("x"), "testdata/b.go": f("x"), "p/testdata/c.go": f("x"), "testdata/embed/d.bin": f("x"), "embed/testdata/e.bin": f("x"), "vendor/testdata/f.go": f("x")}, []string{"a.go"}},
		{"bytewise order, not walk order", fstest.MapFS{"a/b.go": f("x"), "a.go": f("x"), "a-b.go": f("x"), "B.go": f("x")}, []string{"B.go", "a-b.go", "a.go", "a/b.go"}},
		{"testdata prefix is not a testdata segment", fstest.MapFS{"testdata2/a.go": f("x"), "mytestdata/b.go": f("x")}, []string{"mytestdata/b.go", "testdata2/a.go"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := sourceFiles(tt.fs)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("selected = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestSymlinksAreExcludedNotFollowed(t *testing.T) {
	dir := t.TempDir()
	outside := t.TempDir()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "real.go"), []byte("package r\n"), 0o644))
	must(os.WriteFile(filepath.Join(outside, "ext.go"), []byte("package e\n"), 0o644))
	must(os.Mkdir(filepath.Join(outside, "embed"), 0o755))
	must(os.WriteFile(filepath.Join(outside, "embed", "x.bin"), []byte("x"), 0o644))
	for name, target := range map[string]string{
		"filelink.go": filepath.Join(outside, "ext.go"),
		"dirlink":     outside,
		"embed":       filepath.Join(outside, "embed"),
	} {
		if err := os.Symlink(target, filepath.Join(dir, name)); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
	}
	got, err := sourceFiles(os.DirFS(dir))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"real.go"}; !reflect.DeepEqual(got, want) {
		t.Errorf("selected = %v, want %v", got, want)
	}
}

func TestHashFormat(t *testing.T) {
	fsys := fstest.MapFS{"a.go": {Data: []byte("package a\n")}}
	got, err := HashFS(fsys)
	if err != nil {
		t.Fatal(err)
	}
	fileSum := sha256.Sum256([]byte("package a\n"))
	manifest := "a.go\x00" + hex.EncodeToString(fileSum[:]) + "\n"
	sum := sha256.Sum256([]byte(manifest))
	if want := "sha256:" + hex.EncodeToString(sum[:]); got != want {
		t.Errorf("hash = %q, want %q (manifest %q)", got, want, manifest)
	}
	other, _ := HashFS(fstest.MapFS{"a.go": {Data: []byte("package b\n")}})
	renamed, _ := HashFS(fstest.MapFS{"b.go": {Data: []byte("package a\n")}})
	if got == other || got == renamed {
		t.Errorf("hash must cover both content and path: %q %q %q", got, other, renamed)
	}
}

func TestHashFSDetectsContentAndPathChangesAcrossSeparators(t *testing.T) {
	// "a.go\0<h>\n" framing: two files cannot be rearranged into one another's manifest.
	a, _ := HashFS(fstest.MapFS{"a.go": {Data: []byte("1")}, "b.go": {Data: []byte("2")}})
	b, _ := HashFS(fstest.MapFS{"a.go": {Data: []byte("2")}, "b.go": {Data: []byte("1")}})
	if a == "" || a == b {
		t.Errorf("swapping contents must change the hash: %q vs %q", a, b)
	}
}

func TestHardErrors(t *testing.T) {
	f := &fstest.MapFile{Data: []byte("x")}
	tests := []struct {
		name string
		fs   fstest.MapFS
		want error
	}{
		{"newline in path", fstest.MapFS{"a\nb.go": f, "ok.go": f}, ErrUnsafePath},
		{"NUL in path", fstest.MapFS{"a\x00b.go": f, "ok.go": f}, ErrUnsafePath},
		{"newline in directory name", fstest.MapFS{"d\ne/x.go": f}, ErrUnsafePath},
		{"empty tree", fstest.MapFS{}, ErrEmptySet},
		{"only excluded files", fstest.MapFS{"README.md": f, "a_test.go": f, "testdata/a.go": f}, ErrEmptySet},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h, err := HashFS(tt.fs)
			if !errors.Is(err, tt.want) || h != "" {
				t.Errorf("HashFS = (%q, %v), want (\"\", %v)", h, err, tt.want)
			}
			if _, err := sourceFiles(tt.fs); !errors.Is(err, tt.want) {
				t.Errorf("sourceFiles err = %v, want %v", err, tt.want)
			}
		})
	}
}

func TestUnsafePathInExcludedFileIsNotAnError(t *testing.T) {
	// Only paths that would enter the manifest can corrupt it.
	f := &fstest.MapFile{Data: []byte("x")}
	if _, err := HashFS(fstest.MapFS{"ok.go": f, "weird\nname.txt": f}); err != nil {
		t.Errorf("unselected odd path must not fail the hash: %v", err)
	}
}

func TestSourceHashMissingRootIsNotAnEmptySet(t *testing.T) {
	_, err := SourceHash(filepath.Join(t.TempDir(), "nope"))
	if err == nil || errors.Is(err, ErrEmptySet) {
		t.Errorf("a missing root is absent-input, not empty-set: %v", err)
	}
}

func TestSourceHashRealDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.go"), []byte("package a\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := SourceHash(dir)
	want, _ := HashFS(os.DirFS(dir))
	if err != nil || got == "" || got != want {
		t.Errorf("SourceHash = (%q, %v), want %q", got, err, want)
	}
}

func TestSourceHashMain(t *testing.T) {
	run := func(args ...string) (int, string, string) {
		var out, errOut bytes.Buffer
		code := SourceHashMain(args, cli.Stdio{Out: &out, Err: &errOut})
		return code, out.String(), errOut.String()
	}
	t.Run("prints the hash and a newline", func(t *testing.T) {
		code, out, errOut := run(fixtureDir)
		if want := expectedFixtureHash(t) + "\n"; code != cli.ExitOK || out != want || errOut != "" {
			t.Errorf("got (%d, %q, %q), want (0, %q, \"\")", code, out, errOut, want)
		}
	})
	t.Run("usage", func(t *testing.T) {
		for _, args := range [][]string{{}, {"a", "b"}, {"--bogus"}} {
			code, out, errOut := run(args...)
			if code != cli.ExitUsage || out != "" || errOut == "" {
				t.Errorf("%v: got (%d, %q, %q), want exit 2 with a stderr message", args, code, out, errOut)
			}
		}
	})
	t.Run("empty set is operational", func(t *testing.T) {
		code, out, errOut := run(t.TempDir())
		if code != cli.ExitOperational || out != "" || !strings.Contains(errOut, "no source files matched") {
			t.Errorf("got (%d, %q, %q)", code, out, errOut)
		}
	})
}
