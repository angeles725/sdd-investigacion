package secretscan

import (
	"bytes"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// --files-from scans EXACTLY the files of a NUL-delimited list of absolute paths under the target: no corpus-root
// narrowing, and the same name and directory scope as a walk. Three input states are told apart (kit CLAUDE.md
// section 7): an absent or unreadable list is a usage error (exit 2); an empty list, an entry that is gone, outside
// the target or unreadable is DEGRADED (exit 3); a list whose entries are all out of scope is a typed no-match.

// readList returns the raw bytes of the list (a file, or stdin for "-").
func (s *session) readList() ([]byte, *stop) {
	if s.req.FilesFrom == "-" {
		var in io.Reader = bytes.NewReader(nil)
		if s.req.Stdin != nil {
			in = s.req.Stdin
		}
		b, err := io.ReadAll(in)
		if err != nil {
			return nil, s.fail(rcDegraded, "DEGRADED: could not read the --files-from list from stdin")
		}
		if len(b) == 0 {
			return nil, s.fail(rcDegraded, "DEGRADED: --files-from list is empty (0 bytes) — an empty file set is not a clean scan")
		}
		return b, nil
	}
	b, err := os.ReadFile(s.resolve(s.req.FilesFrom))
	if fi, serr := os.Stat(s.resolve(s.req.FilesFrom)); err != nil || serr != nil || !fi.Mode().IsRegular() {
		return nil, s.fail(rcUsage, "usage: --files-from list file not found or unreadable: "+s.req.FilesFrom)
	}
	if len(b) == 0 {
		return nil, s.fail(rcDegraded, "DEGRADED: --files-from list is empty (0 bytes) — an empty file set is not a clean scan")
	}
	return b, nil
}

// splitList is `while read -r -d ”`: NUL separated, a last entry without its NUL counted when non-empty, empty
// entries skipped.
func splitList(b []byte) []string {
	var out []string
	for _, e := range bytes.Split(b, []byte{0}) {
		if len(e) > 0 {
			out = append(out, string(e))
		}
	}
	return out
}

// loadFilesFrom validates every entry in list order; the first bad entry stops the scan (exit 3).
func (s *session) loadFilesFrom() (fileSet, *stop) {
	var set fileSet
	b, st := s.readList()
	if st != nil {
		return set, st
	}
	root, err := filepath.EvalSymlinks(s.abs)
	if err != nil {
		return set, s.fail(rcDegraded, "DEGRADED: cannot resolve the target directory")
	}
	var lastDir string
	var lastOK bool
	for _, f := range splitList(b) {
		set.Listed++
		rel, inside := strings.CutPrefix(f, root+"/")
		if !inside {
			return set, s.fail(rcDegraded, "DEGRADED: --files-from entry is outside the target ("+root+"): "+f)
		}
		if comp := "/" + rel + "/"; strings.Contains(comp, "/../") || strings.Contains(comp, "/./") || strings.Contains(comp, "//") {
			return set, s.fail(rcDegraded, "DEGRADED: --files-from entry has a '.', '..' or empty path component: "+f)
		}
		fi, err := os.Lstat(f)
		switch {
		case err == nil && fi.Mode()&fs.ModeSymlink != 0: // never dereferenced: skipped and counted
			set.NonReg++
			continue
		case err != nil:
			return set, s.fail(rcDegraded, "DEGRADED: --files-from entry does not exist (vanished since the list was built?): "+f)
		case !fi.Mode().IsRegular():
			set.NonReg++
			continue
		case !pathInScope(rel):
			continue
		}
		if !readable(f) {
			return set, s.fail(rcDegraded, "DEGRADED: --files-from in-scope entry is not readable: "+f)
		}
		// the canonical directory must equal the literal one: no symlinked directory on the way, nothing outside.
		if dir := f[:strings.LastIndexByte(f, '/')]; dir != lastDir {
			lastDir = dir
			real, err := filepath.EvalSymlinks(dir)
			lastOK = err == nil && real == dir && strings.HasPrefix(real+"/", root+"/")
		}
		if !lastOK {
			return set, s.fail(rcDegraded, "DEGRADED: --files-from entry is outside the target or reached through a symlinked directory: "+f)
		}
		set.Files = append(set.Files, scanFile{Display: f, Abs: f})
		set.InScope++
	}
	return set, nil
}

// readable is `[ -r path ]`: this process can open the file for reading.
func readable(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}
