package cishard

import (
	"errors"
	"io"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// errNoStdin is an absent standard input: the command was given no reader at all.
var errNoStdin = errors.New("no standard input")

// readStdin reads the whole standard input.
func readStdin(s cli.Stdio) ([]byte, error) {
	if s.In == nil {
		return nil, errNoStdin
	}
	return io.ReadAll(s.In)
}

// readPath reads a file named on the command line; a relative path is relative to the working directory of the Stdio.
func readPath(s cli.Stdio, path string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		path = filepath.Join(s.Cwd, path)
	}
	return os.ReadFile(path)
}
