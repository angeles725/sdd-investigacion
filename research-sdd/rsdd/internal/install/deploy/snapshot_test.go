//go:build unix && !nodiff

package deploy

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var hexDigest = regexp.MustCompile(`[0-9a-f]{64}`)

// mktempName is the random suffix mktemp gives a file in TMPDIR (`tmp.` plus ten characters).
var mktempName = regexp.MustCompile(`\btmp\.[A-Za-z0-9]{10}\b`)

// utcStamp is the `date -u +%Y%m%dT%H%M%SZ` stamp the installer embeds in a backup directory name.
var utcStamp = regexp.MustCompile(`[0-9]{8}T[0-9]{6}Z`)

// normalize makes captured text independent of the scratch root: the root becomes <ROOT>, every sha256 digest
// becomes <sha256> (a digest of a file that embeds the root path, the launcher block, changes per run), a UTC
// backup stamp becomes <UTC> and a mktemp name becomes tmp.<RAND>.
func (w *world) normalize(s string) string {
	s = hexDigest.ReplaceAllString(strings.ReplaceAll(s, w.root, "<ROOT>"), "<sha256>")
	s = utcStamp.ReplaceAllString(s, "<UTC>")
	return mktempName.ReplaceAllString(s, "tmp.<RAND>")
}

// snapshot lists every entry below dir, one line each, sorted by path: type, permission bits, and for a file the
// size and the sha256 of its normalized content, for a symlink its normalized target. dir itself is not listed.
func (w *world) snapshot(dir string) string {
	w.t.Helper()
	var lines []string
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == dir {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		perm := fi.Mode().Perm()
		switch {
		case fi.Mode()&os.ModeSymlink != 0:
			target, _ := os.Readlink(p)
			lines = append(lines, fmt.Sprintf("L %s -> %s", w.normalize(rel), w.normalize(target)))
		case fi.IsDir():
			lines = append(lines, fmt.Sprintf("D %04o %s", perm, w.normalize(rel)))
		case fi.Mode().IsRegular():
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			txt := w.normalize(string(b))
			sum := sha256.Sum256([]byte(txt))
			lines = append(lines, fmt.Sprintf("F %04o %s %d %s", perm, w.normalize(rel), len(txt), hex.EncodeToString(sum[:8])))
		default:
			lines = append(lines, fmt.Sprintf("? %v %s", fi.Mode(), w.normalize(rel)))
		}
		return nil
	})
	if err != nil {
		w.t.Fatal(err)
	}
	if len(lines) == 0 {
		return ""
	}
	sort.Strings(lines)
	return strings.Join(lines, "\n") + "\n"
}

// read returns the normalized text of a file below the scratch root, for assertions on a single file's bytes.
func (w *world) read(abs string) string {
	w.t.Helper()
	b, err := os.ReadFile(abs)
	if err != nil {
		w.t.Fatal(err)
	}
	return w.normalize(string(b))
}
