package place

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// archive is the --replace step for an existing dest. Identical bytes that are already registered drop part and
// report same. Different bytes are kept as <stem>.<first 12 hex of their sha256>.<ext> (<name>.<12 hex> without an
// extension) and the old row's File cell is retargeted to that name, sha-scoped. If the versioned name is a
// symlink, or already holds DIFFERENT bytes, the run REFUSES (exit 1) and the current bytes stay in place.
func (p *Placer) archive(part, dest, rel string) (same bool, code int) {
	oldSHA, err := srcregistry.FileSHA256(dest)
	if err != nil {
		return false, p.hashFailed(dest, err)
	}
	newSHA, err := srcregistry.FileSHA256(part)
	if err != nil {
		return false, p.hashFailed(part, err)
	}
	if oldSHA == newSHA {
		if has, _ := srcregistry.Has(p.SDir, rel, newSHA); has {
			_ = os.Remove(part)
			fmt.Fprintf(p.Err, "fetch-doc: identical bytes already registered for %s; nothing replaced, no new row\n", rel)
			return true, 0
		}
		return false, 0
	}
	vname := versionedName(filepath.Base(dest), oldSHA)
	vpath := filepath.Join(filepath.Dir(dest), vname)
	if isLink(vpath) {
		fmt.Fprintf(p.Err, "fetch-doc: REFUSED: versioned name is a symlink: %s — the current bytes are kept; remove it and re-run\n", vpath)
		return false, ExitFailure
	}
	if exists(vpath) {
		// A->B->A->B: the same bytes may already be archived there; anything else must NOT be destroyed or merged.
		if got, err := srcregistry.FileSHA256(vpath); err != nil || got != oldSHA {
			fmt.Fprintf(p.Err, "fetch-doc: REFUSED: versioned name already holds DIFFERENT bytes: %s — the current bytes are kept\n", vpath)
			return false, ExitFailure
		}
		_ = os.Remove(dest)
	} else if err := os.Rename(dest, vpath); err != nil {
		fmt.Fprintf(p.Err, "fetch-doc: could not archive the old bytes of %s as %s: %v\n", dest, vname, err)
		return false, ExitFailure
	}
	others, err := srcregistry.Retarget(p.SDir, rel, sibling(rel, vname), oldSHA)
	if err != nil {
		fmt.Fprintf(p.Err, "fetch-doc: could not update %s: %v\n", srcregistry.SourcesFile, err)
		return false, ExitFailure
	}
	if others > 0 {
		fmt.Fprintf(p.Err, "fetch-doc: WARNING: %d other row(s) for %s carry a different sha256 than the archived bytes and were left untouched\n", others, rel)
	}
	fmt.Fprintf(p.Err, "fetch-doc: replaced %s; old bytes kept as %s\n", dest, vname)
	return false, 0
}

func (p *Placer) hashFailed(path string, err error) int {
	fmt.Fprintf(p.Err, "fetch-doc: cannot hash %s: %v\n", path, err)
	return ExitFailure
}

// versionedName is where the old bytes of base go: the stem, the first 12 hex of their sha256, the extension.
func versionedName(base, sha string) string {
	stem, ext := base, ""
	if i := strings.LastIndex(base, "."); i >= 0 {
		stem, ext = base[:i], base[i:]
	}
	return stem + "." + sha[:versionedSHALen] + ext
}
