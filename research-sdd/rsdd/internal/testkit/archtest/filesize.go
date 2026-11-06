package archtest

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// The file-size ratchet: the scan and its result. The limits are in filesize_limits.go, the messages in
// filesize_judge.go.

// SizeResult reports what CheckFileSizes examined as well as what it found,
// so a zero cannot be mistaken for "did not look".
type SizeResult struct {
	Scanned    int      // production files measured (generated files excluded)
	Generated  int      // generated files exempted
	Over       int      // production files over SoftLimit
	Entries    int      // well-formed debt entries read
	Lowerable  int      // entries at HardLimit or less whose count is above the file's current count (still over SoftLimit)
	Violations []string // exact, actionable messages, sorted
}

// Summary is the one-line reading of a run. The real-tree test prints it, and a test fixes its format.
func (r SizeResult) Summary() string {
	return fmt.Sprintf("modularity: scanned=%d generated=%d over%d=%d entries=%d lowerable=%d",
		r.Scanned, r.Generated, SoftLimit, r.Over, r.Entries, r.Lowerable)
}

var generatedLine = regexp.MustCompile(`^// Code generated .* DO NOT EDIT\.$`)

// CheckFileSizes measures every production Go file under root against the
// limits and the debt list at debtPath. A missing debt file, an unreadable
// source file, or a tree with no production file is an error, never a pass.
func CheckFileSizes(root, debtPath string) (SizeResult, error) {
	var r SizeResult
	files, generated, err := scanProduction(root)
	if err != nil {
		return r, err
	}
	data, err := os.ReadFile(debtPath)
	if err != nil {
		return r, fmt.Errorf("archtest: cannot read debt file: %w", err)
	}
	entries, bad, malformed := parseDebt(string(data))
	r.Scanned, r.Generated, r.Entries = len(files), generated, len(entries)
	r.Violations = append(bad, judge(files, entries, malformed, &r)...)
	sort.Strings(r.Violations)
	return r, nil
}

// scanProduction returns root-relative slash path -> line count for every
// production Go file, plus how many generated files were exempted. It does
// not enter testdata or a directory the go tool ignores.
func scanProduction(root string) (map[string]int, int, error) {
	files := map[string]int{}
	generated := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("archtest: cannot read %s: %w", path, err)
		}
		if d.IsDir() {
			if path != root && skipDir(d.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if goIgnores(d.Name()) || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("archtest: cannot read %s: %w", path, err)
		}
		if isGenerated(b) {
			generated++
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		files[filepath.ToSlash(rel)] = countLines(b)
		return nil
	})
	if err != nil {
		return nil, 0, err
	}
	if len(files) == 0 {
		return nil, 0, errors.New("archtest: no production Go files under " + root + " (an empty scan proves nothing)")
	}
	return files, generated, nil
}

// skipDir reports a directory the scan does not enter: testdata, and the names the go tool ignores. The root
// itself is always entered, whatever it is called.
func skipDir(name string) bool { return name == "testdata" || goIgnores(name) }

// goIgnores reports a file or directory name the go tool ignores, one starting with "." or "_": such a path is
// not part of the module (a scratch copy, a draft, an editor's lock symlink).
func goIgnores(name string) bool { return strings.HasPrefix(name, ".") || strings.HasPrefix(name, "_") }

// countLines is the number of \n bytes, plus one for a non-empty file that
// does not end in \n.
func countLines(b []byte) int {
	n := bytes.Count(b, []byte{'\n'})
	if len(b) > 0 && b[len(b)-1] != '\n' {
		n++
	}
	return n
}

// isGenerated reports a "// Code generated ... DO NOT EDIT." line before the
// package clause.
func isGenerated(b []byte) bool {
	for _, line := range bytes.Split(b, []byte{'\n'}) {
		line = bytes.TrimRight(line, "\r")
		if generatedLine.Match(line) {
			return true
		}
		if bytes.HasPrefix(line, []byte("package ")) {
			return false
		}
	}
	return false
}
