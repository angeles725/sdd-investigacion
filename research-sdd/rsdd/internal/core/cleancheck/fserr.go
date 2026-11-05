package cleancheck

import (
	"errors"
	"io/fs"
	"os"
	"sort"
	"strings"
	"syscall"
)

// findError is a directory find could not read: the path and what find would print for it.
type findError struct {
	path   string
	denied bool   // Permission denied: the one shape the evidence discovery tells apart
	reason string // the text after the path
}

// line is the C-locale GNU find diagnostic: find: '<path>': <reason>.
func (e findError) line() string { return "find: '" + e.path + "': " + e.reason }

func newFindError(path string, err error) findError {
	switch {
	case errors.Is(err, fs.ErrPermission):
		return findError{path, true, "Permission denied"}
	case errors.Is(err, syscall.ENOTDIR):
		return findError{path, false, "Not a directory"}
	default:
		var pe *fs.PathError
		if errors.As(err, &pe) {
			err = pe.Err
		}
		return findError{path, false, capitalize(err.Error())}
	}
}

func capitalize(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// vanished is a directory entry that went away between listing and reading: -ignore_readdir_race makes it benign.
func vanished(err error) bool { return errors.Is(err, fs.ErrNotExist) }

// entry is one directory entry of a walk.
type entry struct {
	name string
	info fs.FileInfo // lstat: a symlink is a symlink
}

// listDir lists dir sorted by name (bytewise). An entry that vanishes while it is being read is left out.
func listDir(dir string) ([]entry, error) {
	des, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var out []entry
	for _, de := range des {
		info, err := de.Info()
		if err != nil {
			if vanished(err) {
				continue
			}
			return nil, err
		}
		out = append(out, entry{de.Name(), info})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].name < out[j].name })
	return out, nil
}

// join is `$dir/$name`, without a doubled slash when dir is the root.
func join(dir, name string) string {
	if dir == "/" {
		return "/" + name
	}
	return dir + "/" + name
}
