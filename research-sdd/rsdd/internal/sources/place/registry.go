package place

import (
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// registered asks SOURCES.md whether file (with sha, "" for any) has a row. An absent SOURCES.md legitimately has
// no rows; one that exists but cannot be read (no permission, a directory in its place) is NOT "no row": a caller
// that acted on that would delete or move registered evidence. It then prints a typed notice naming the file and
// returns ExitFailure; refusing is what: the step that was not done ("nothing swept", "nothing replaced").
func (p *Placer) registered(file, sha, what string) (has bool, code int) {
	has, err := srcregistry.Has(p.SDir, file, sha)
	if err != nil {
		path := filepath.Join(p.SDir, srcregistry.SourcesFile)
		var pe *fs.PathError
		if errors.As(err, &pe) {
			err = pe.Err
		}
		fmt.Fprintf(p.Err, "fetch-doc: REFUSED: cannot read %s: %v — %s\n", path, err, what)
		return false, ExitFailure
	}
	return has, 0
}
