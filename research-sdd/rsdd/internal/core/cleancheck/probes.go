package cleancheck

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// probes is what <target>/sources/probes already preserves: the script names its manifests list, and the sha256 of
// every file under it (a scratchpad file with a byte-identical copy there is preserved).
type probes struct {
	manifested map[string]bool
	shas       map[string]bool
}

// hasCopy reports whether a byte-identical copy of the file sits under sources/probes. A file that cannot be read
// has no copy: the file stays a finding.
func (p probes) hasCopy(path string) bool {
	sum, ok := fileSum(path)
	return ok && p.shas[sum]
}

// fileSum is the sha256 of the file, streamed: an artifact of any size is hashed in constant memory, as
// `sha256sum < file` did. A file that cannot be opened or read has no sum.
func fileSum(path string) (string, bool) {
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", false
	}
	return hex.EncodeToString(h.Sum(nil)), true
}

// readProbes reads the manifests and hashes the files under sources/probes. A scan that fails is a refused run
// (never "no manifests"); a target without sources/probes has neither.
func (r *run) readProbes() (probes, bool) {
	p := probes{manifested: map[string]bool{}, shas: map[string]bool{}}
	root := r.targetP + "/sources/probes"
	// find <dir> -type f does not follow a symlinked <dir>: a sources/probes that links elsewhere has no files, and
	// reading through it would trust what lies outside the target.
	if fi, err := r.lstat(root); err != nil || !fi.IsDir() {
		return p, true
	}
	var manifests, files []string
	errs := walkTree(root, -1, func(path string, _ int, e entry) bool {
		if e.info.Mode().IsRegular() {
			files = append(files, path)
			if e.name == manifestName {
				manifests = append(manifests, path)
			}
		}
		return true
	})
	if len(errs) > 0 {
		r.stderr(strings.Join(findStderr(errs), "\n"))
		return p, r.refuse("manifest scan failed under " + root + "; UNMANIFESTED-SCRIPT not evaluated")
	}
	for _, mf := range manifests {
		rows, ok := kit.ScriptsManifestRows(fsview.View{Cwd: r.o.Cwd}, r.targetP, mf)
		if !ok {
			return p, r.refuse("cannot parse manifest " + mf)
		}
		for _, row := range rows {
			cell, _, _ := strings.Cut(row, "\t")
			if base := cell[strings.LastIndex(cell, "/")+1:]; base != "" {
				p.manifested[base] = true
			}
		}
	}
	for _, f := range files {
		if sum, ok := fileSum(f); ok {
			p.shas[sum] = true
		}
	}
	return p, true
}
