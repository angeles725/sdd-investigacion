package consumers

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// binaryProbe is how much of a file is looked at for a NUL byte (issue #2758, S17).
const binaryProbe = 8192

// fileResult is what one file names: references to other scripts by basename, and how many times a live script
// names itself (not a consumer of itself).
type fileResult struct {
	path, class string
	refs        map[string]int
	self        int
}

// scanned is everything one pass over the files learned.
type scanned struct {
	results    []fileResult
	total      map[string]int // files per class, read or not
	goModule   int
	fixtures   int
	binary     int
	notRegular int
	binaryBy   map[string]int
	errs       []string
}

// scan reads every file that is not in the Go module or a fixtures directory and counts the names in it. A file
// that cannot be read is an error entry naming it, never a skipped file.
func scan(top string, files []string, live, names map[string]bool) scanned {
	sn := scanned{total: map[string]int{}, binaryBy: map[string]int{}}
	for _, f := range files {
		class := classify(f, live)
		sn.total[class]++
		if class == classGo {
			sn.goModule++
			continue
		}
		if class == classFixtures {
			sn.fixtures++
			continue
		}
		b, err := readRegular(filepath.Join(top, filepath.FromSlash(f)))
		if errors.Is(err, errNotRegular) {
			sn.notRegular++
			continue
		}
		if err != nil {
			sn.errs = append(sn.errs, fmt.Sprintf(errCannotRead, f, why(err)))
			continue
		}
		if bytes.IndexByte(b[:min(len(b), binaryProbe)], 0) >= 0 {
			sn.binary++
			sn.binaryBy[class]++
			continue
		}
		r := fileResult{path: f, class: class, refs: countNames(b, names)}
		if live[f] {
			r.self = r.refs[baseName(f)]
			delete(r.refs, baseName(f))
		}
		sn.results = append(sn.results, r)
	}
	return sn
}

var errNotRegular = errors.New("not a regular file")

// readRegular reads a regular file; a symbolic link, a directory (a submodule) or a device is errNotRegular.
func readRegular(p string) ([]byte, error) {
	fi, err := os.Lstat(p)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errNotRegular
	}
	return os.ReadFile(p)
}

// why is the operating system's reason without the path it repeats.
func why(err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return err.Error()
}

func (r fileResult) total() int {
	n := 0
	for _, c := range r.refs {
		n += c
	}
	return n
}
