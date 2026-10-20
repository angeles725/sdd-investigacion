package commands

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The source hash fingerprints the Go sources a binary was built from, so
// `rsdd version --source-hash` can tell whether a binary is stale.
//
// Selection, evaluated on paths RELATIVE to the root (the root's own path is
// never matched, so a fixture under testdata/ still hashes):
//   - every *.go except *_test.go;
//   - go.mod and go.sum at the root, when present;
//   - every file under the root's vendor/, when present;
//   - every file under any directory named embed/;
//   - minus any path with a `testdata` segment.
//
// Only regular files count: symlinks are neither hashed nor followed. The
// working tree is read, not the index.
//
// Manifest: one line per selected path, sorted bytewise, forward slashes, no
// leading "./": <path> NUL <lowercase hex sha256 of content> LF. The value is
// "sha256:" + lowercase hex sha256 of the manifest.

// Typed hard failures: never skipped, never degraded to a partial hash.
var (
	// ErrEmptySet means nothing was selected: a hash of nothing proves nothing.
	ErrEmptySet = errors.New("source-hash: no source files matched")
	// ErrUnsafePath means a selected path contains LF or NUL, which would make
	// the manifest ambiguous.
	ErrUnsafePath = errors.New("source-hash: selected path contains a newline or NUL")
)

// selected reports whether the root-relative slash path joins the hashed set.
func selected(rel string) bool {
	segs := strings.Split(rel, "/")
	for _, s := range segs {
		if s == "testdata" {
			return false
		}
	}
	base := segs[len(segs)-1]
	switch {
	case strings.HasSuffix(base, ".go"):
		return !strings.HasSuffix(base, "_test.go")
	case rel == "go.mod", rel == "go.sum":
		return true
	case segs[0] == "vendor" && len(segs) > 1:
		return true
	}
	for _, s := range segs[:len(segs)-1] {
		if s == "embed" {
			return true
		}
	}
	return false
}

// sourceFiles returns the selected paths, sorted bytewise.
func sourceFiles(fsys fs.FS) ([]string, error) {
	var files []string
	err := fs.WalkDir(fsys, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.Type().IsRegular() || !selected(p) {
			return nil
		}
		if strings.ContainsAny(p, "\n\x00") {
			return fmt.Errorf("%w: %q", ErrUnsafePath, p)
		}
		files = append(files, p)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if len(files) == 0 {
		return nil, ErrEmptySet
	}
	// WalkDir orders per directory, not by full path ("a.go" < "a/b.go").
	sort.Strings(files)
	return files, nil
}

// HashFS computes the source hash over fsys.
func HashFS(fsys fs.FS) (string, error) {
	files, err := sourceFiles(fsys)
	if err != nil {
		return "", err
	}
	manifest := sha256.New()
	for _, p := range files {
		sum, err := fileSum(fsys, p)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(manifest, "%s\x00%s\n", p, sum)
	}
	return "sha256:" + hex.EncodeToString(manifest.Sum(nil)), nil
}

func fileSum(fsys fs.FS, p string) (string, error) {
	f, err := fsys.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("source-hash: read %s: %w", p, err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// SourceHash computes the source hash of the tree at root.
func SourceHash(root string) (string, error) { return HashFS(os.DirFS(root)) }

// SourceHashMain is the entry point of cmd/rsdd-srchash: print the hash of the
// single directory argument and a newline.
func SourceHashMain(args []string, s cli.Stdio) int {
	fs := flag.NewFlagSet("rsdd-srchash", flag.ContinueOnError)
	fs.SetOutput(s.Err)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return cli.ExitOK
		}
		return cli.ExitUsage
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(s.Err, "usage: rsdd-srchash <root>")
		return cli.ExitUsage
	}
	h, err := SourceHash(fs.Arg(0))
	if err != nil {
		fmt.Fprintf(s.Err, "rsdd-srchash: %v\n", err)
		return cli.ExitOperational
	}
	fmt.Fprintln(s.Out, h)
	return cli.ExitOK
}
