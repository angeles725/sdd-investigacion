package secretscan

import (
	"bufio"
	"bytes"
	"io"
	"strings"
)

// Enumeration: `rev-list HEAD | diff-tree --stdin -r -m --root --no-renames --no-abbrev -z --no-commit-id` emits,
// for every file change, ":<old-mode> <new-mode> <old-sha> <new-sha> <status>\0<path>\0". -m yields one diff per
// parent of a merge, so content added only by an evil merge is covered. Unlike `rev-list --objects` every (blob,
// path) pair appears, so an in-scope path alias for a blob first seen under an excluded path is never missed.

// blobSet maps a blob sha to the smallest in-scope path it appears under (the report names that one).
type blobSet map[string]string

// enumResult is what enumeration found.
type enumResult struct {
	Blobs   blobSet
	Records int    // NUL-terminated records the plumbing produced (0 = nothing was listed)
	Fail    string // a malformed-record message (fail-closed): the enumeration cannot be trusted
	RC      [2]int // exit codes of rev-list and diff-tree
}

const zeros = "0"

// validHeader is the strict shape of a diff-tree header record: five single-space separated fields, no tab, no
// double space, no trailing space, 6-digit octal modes, 40..64 hex digit shas, one status letter plus digits.
func validHeader(rec string) ([]string, bool) {
	if strings.ContainsAny(rec, "\t") || strings.Contains(rec, "  ") || strings.HasSuffix(rec, " ") {
		return nil, false
	}
	f := strings.Split(rec, " ")
	if len(f) != 5 || !isMode(f[0][1:]) || !isMode(f[1]) || !isSha(f[2]) || !isSha(f[3]) || !isStatus(f[4]) {
		return nil, false
	}
	return f, true
}

func isMode(s string) bool {
	if len(s) != 6 {
		return false
	}
	for i := 0; i < 6; i++ {
		if s[i] < '0' || s[i] > '7' {
			return false
		}
	}
	return true
}

func isSha(s string) bool {
	if len(s) < 40 || len(s) > 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if c := s[i]; !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func isStatus(s string) bool {
	if s == "" || s[0] < 'A' || s[0] > 'Z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// enumerate runs the two plumbing commands and filters their output.
func (s *session) enumerate() enumResult {
	res := enumResult{Blobs: blobSet{}}
	rl, err := s.git.Start(s.abs, nil, "--no-replace-objects", "rev-list", "HEAD")
	if err != nil {
		res.RC = [2]int{127, 127}
		return res
	}
	revs, _ := io.ReadAll(rl.Stdout())
	res.RC[0] = rl.Wait()
	dt, err := s.git.Start(s.abs, bytes.NewReader(revs), "--no-replace-objects", "diff-tree", "--stdin", "-r", "-m",
		"--root", "--no-renames", "--no-abbrev", "-z", "--no-commit-id")
	if err != nil {
		res.RC[1] = 127
		return res
	}
	r := bufio.NewReaderSize(dt.Stdout(), 1<<16)
	sha, expectPath := "", false
	for {
		rec, err := r.ReadString(0)
		if len(rec) == 0 && err != nil {
			break
		}
		rec = strings.TrimSuffix(rec, "\x00")
		res.Records++
		if res.Fail != "" {
			continue // drain: the process must finish and report its own code first
		}
		switch {
		case expectPath && rec != "":
			expectPath = false
			res.addPath(sha, rec)
			sha = ""
		case strings.HasPrefix(rec, ":"):
			f, ok := validHeader(rec)
			if !ok {
				res.Fail = "DEGRADED: malformed diff-tree header: " + clip(rec, 80)
				continue
			}
			sha, expectPath = f[3], true
			if f[1] == "160000" { // a gitlink is a submodule commit, not a blob: skip it and its path
				sha = ""
			}
		case rec != "":
			res.Fail = "DEGRADED: unexpected non-header record in diff-tree output: " + clip(rec, 80)
		}
	}
	res.RC[1] = dt.Wait()
	return res
}

// addPath keeps the smallest in-scope path of a live (non-deleted) blob.
func (res *enumResult) addPath(sha, path string) {
	if sha == "" || strings.Trim(sha, zeros) == "" || !pathInScope(path) {
		return
	}
	path = strings.ReplaceAll(path, "\n", `\n`) // one report line per entry
	if old, ok := res.Blobs[sha]; ok {
		path = min(path, old)
	}
	res.Blobs[sha] = path
}

func clip(s string, n int) string {
	return s[:min(len(s), n)]
}
