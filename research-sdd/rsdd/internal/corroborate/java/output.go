package java

import (
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// outputRecord is one file an adapter left under engines/<name>/output, as the report inventories it.
type outputRecord struct {
	path   string
	size   int64
	sha256 string
}

func (r outputRecord) asMap() map[string]any {
	return map[string]any{"path": r.path, "size": r.size, "sha256": r.sha256}
}

// walk lists every entry below root (root itself excluded), refusing any symlink. A missing root lists nothing.
func walk(root, symlinkMsg string) (files, dirs []string, err error) {
	if _, serr := os.Lstat(root); serr != nil {
		return nil, nil, nil
	}
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
		if werr != nil || p == root {
			return nil // an entry that vanished mid-walk has nothing to count
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			return fail("%s", symlinkMsg)
		case d.IsDir():
			dirs = append(dirs, p)
		case d.Type().IsRegular():
			files = append(files, p)
		}
		return nil
	})
	return files, dirs, err
}

// scanFiles is scan_files: how many regular files and bytes sit below root, stopping as soon as a cap is passed.
// A symlink anywhere is a failure.
func scanFiles(root string, maxFiles, maxBytes int64) (files, total int64, err error) {
	if _, serr := os.Lstat(root); serr != nil {
		return 0, 0, nil
	}
	stop := fs.SkipAll
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
		if werr != nil || p == root {
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return fail("adapter emitted a symlink: %s", p)
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if fi, serr := d.Info(); serr == nil {
			files++
			total += fi.Size()
		}
		if files > maxFiles || total > maxBytes {
			return stop
		}
		return nil
	})
	return files, total, err
}

// outputContainsBytes is output_contains_bytes: whether any file below output is not empty.
func outputContainsBytes(output string) (bool, error) {
	files, _, err := walk(output, "adapter output symlink is forbidden")
	if err != nil {
		return false, err
	}
	for _, p := range files {
		if fi, serr := os.Stat(p); serr == nil && fi.Size() > 0 {
			return true, nil
		}
	}
	return false, nil
}

// normalizeDiagnostics is normalize_diagnostics: stdout.raw.txt and stderr.raw.txt become stdout.txt and
// stderr.txt within one shared byte budget, with the staging root and the sandbox root replaced by
// <STAGING_ROOT>. It returns the budget left and whether anything was cut.
func normalizeDiagnostics(engineRoot, stage string, maxBytes int64) (int64, bool, error) {
	marker := []byte("<STAGING_ROOT>")
	variants := [][]byte{[]byte(stage), []byte(sandboxRoot)}
	remaining, truncated := maxBytes, false
	for _, stream := range []string{"stdout", "stderr"} {
		rawPath := filepath.Join(engineRoot, stream+".raw.txt")
		var payload []byte
		if f, err := os.Open(rawPath); err == nil {
			payload, err = io.ReadAll(io.LimitReader(f, remaining+1))
			_ = f.Close()
			if err != nil {
				return 0, false, osFailure(err, rawPath)
			}
		}
		consumed := min(int64(len(payload)), remaining)
		if int64(len(payload)) > remaining {
			payload = payload[:remaining]
			truncated = true
		}
		for _, v := range variants {
			if len(v) > 0 {
				payload = bytes.ReplaceAll(payload, v, marker)
			}
		}
		if err := os.WriteFile(filepath.Join(engineRoot, stream+".txt"), payload, 0o666); err != nil {
			return 0, false, osFailure(err, "")
		}
		remaining -= int64(len(payload))
		if fi, err := os.Stat(rawPath); err == nil {
			if fi.Size() > consumed {
				truncated = true
			}
			if err := os.Remove(rawPath); err != nil {
				return 0, false, osFailure(err, rawPath)
			}
		}
	}
	return remaining, truncated, nil
}

// outputInventory is output_inventory: the adapter's files in path order with their identity, cut to maxFiles
// files and maxBytes bytes (a file past the file cap is deleted, one crossing the byte cap is truncated to the
// budget). The empty directories left behind are removed.
func (e *env) outputInventory(stage, output string, maxFiles, maxBytes int64) ([]outputRecord, bool, error) {
	files, _, err := walk(output, "adapter output symlink is forbidden")
	if err != nil {
		return nil, false, err
	}
	sort.Strings(files)
	records := []outputRecord{}
	remaining, truncated := maxBytes, false
	for _, p := range files {
		fi, err := os.Stat(p)
		if err != nil {
			return nil, false, osFailure(err, p)
		}
		if int64(len(records)) >= maxFiles || remaining == 0 {
			if err := os.Remove(p); err != nil {
				return nil, false, osFailure(err, p)
			}
			truncated = true
			continue
		}
		if fi.Size() > remaining {
			if err := truncateRegular(p, remaining); err != nil {
				return nil, false, err
			}
			truncated = true
		}
		_, size, digest, err := fileIdentity(p, stage)
		if err != nil {
			return nil, false, err
		}
		rel := strings.TrimPrefix(p, strings.TrimRight(output, "/")+"/")
		records = append(records, outputRecord{path: rel, size: size, sha256: digest})
		remaining -= size
	}
	_, dirs, err := walk(output, "adapter output symlink is forbidden")
	if err != nil {
		return nil, false, err
	}
	// walk lists a directory before everything below it (filepath.WalkDir is pre-order), so the reverse order removes
	// every directory after all of its descendants: the same deepest-first removal the depth sort gave, with no
	// comparator whose equal-depth case could matter.
	slices.Reverse(dirs)
	for _, d := range dirs {
		_ = os.Remove(d) // a directory that still holds something stays
	}
	return records, truncated, nil
}
