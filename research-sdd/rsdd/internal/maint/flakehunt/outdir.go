package flakehunt

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// defaultOut is ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/flake-hunt/<timestamp>-<pid>.
func defaultOut(getenv func(string) string, now time.Time, pid int) string {
	base := getenv("XDG_STATE_HOME")
	if base == "" {
		base = getenv("HOME") + "/.local/state"
	}
	return fmt.Sprintf("%s/research-sdd/flake-hunt/%s-%d", base, now.Format("20060102T150405"), pid)
}

// resolveOut makes out absolute and physical before anything exists: the nearest existing ancestor is resolved
// (symlinks followed) and the missing tail appended. A `.` or `..` in the missing tail cannot be judged, so it is
// refused. A trailing slash is dropped.
func resolveOut(cwd, out string) (string, *stop) {
	orig := out
	out = kitmaint.Abs(cwd, out)
	base, tail := strings.TrimRight(out, "/"), ""
	for base != "" && !kitmaint.IsDir(base) {
		name := base[strings.LastIndexByte(base, '/')+1:]
		if name == "." || name == ".." {
			return "", die("output directory '%s' has a '.' or '..' component below its first missing directory; pass a normalized --out", orig)
		}
		tail = "/" + name + tail
		base = base[:strings.LastIndexByte(base, '/')]
	}
	if base == "" {
		base = "/"
	}
	phys, err := filepath.EvalSymlinks(base)
	if err != nil {
		return "", die("cannot resolve output directory %s", out)
	}
	return strings.TrimSuffix(phys, "/") + tail, nil
}

// prepareOut judges the output directory and only then creates <out>/logs and an empty results.tsv. It refuses the
// repo itself, anything inside it (also through `.`, `..` or a symlink) and an existing non-empty directory, and it
// never removes a directory it did not create.
func prepareOut(cwd, repo, out string) (dir, results string, fail *stop) {
	dir, fail = resolveOut(cwd, out)
	if fail != nil {
		return "", "", fail
	}
	if kitmaint.Inside(dir, repo) {
		return "", "", die("output directory %s is the repo or inside it (%s); choose another --out", dir, repo)
	}
	if kitmaint.IsDir(dir) {
		if ents, err := os.ReadDir(dir); err != nil || len(ents) > 0 {
			return "", "", die("output directory %s exists and is not empty; choose a fresh --out", dir)
		}
	}
	if err := os.MkdirAll(dir+"/logs", 0o755); err != nil {
		return "", "", die("cannot create output directory %s", dir)
	}
	results = dir + "/results.tsv"
	if err := os.WriteFile(results, nil, 0o644); err != nil {
		return "", "", die("cannot create output directory %s", dir)
	}
	return dir, results, nil
}
