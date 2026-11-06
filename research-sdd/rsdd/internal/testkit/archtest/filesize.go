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
	Lowerable  int      // entries whose recorded count is above the file's current count (still over SoftLimit)
	Violations []string // exact, actionable messages, sorted
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
	entries, bad := parseDebt(string(data))
	r.Scanned, r.Generated, r.Entries = len(files), generated, len(entries)
	r.Violations = append(bad, judge(files, entries, &r)...)
	sort.Strings(r.Violations)
	return r, nil
}

// scanProduction returns root-relative slash path -> line count for every
// production Go file, plus how many generated files were exempted.
func scanProduction(root string) (map[string]int, int, error) {
	files := map[string]int{}
	generated := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == "testdata" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
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
