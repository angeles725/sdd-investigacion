package native

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// abs reads a relative path against the injected working directory, without cleaning it (a ".." after a
// symlink must still mean what the kernel says).
func (j *job) abs(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return j.s.Cwd + "/" + p
}

// identity is the fsx identity of the file the user named; an identity error names the path as typed.
func (j *job) identity(path string) (fsx.Ident, error) {
	id, err := fsx.Identity(j.abs(path), fsx.NoLimit)
	var fe *fsx.Error
	if errors.As(err, &fe) {
		return id, &fsx.Error{Kind: fe.Kind, Path: path, Err: fe.Err}
	}
	return id, err
}

// outputPlace splits the --output argument into the canonical parent directory and the new entry's name.
func (j *job) outputPlace(output string) (parent, name string, err error) {
	trimmed := strings.TrimRight(output, "/")
	if trimmed == "" {
		trimmed = "/"
	}
	dir, name := filepath.Dir(trimmed), filepath.Base(trimmed)
	if trimmed == "/" {
		name = ""
	}
	full := j.abs(dir)
	parent, err = filepath.EvalSymlinks(full)
	if err != nil {
		return "", "", osError(err, full)
	}
	return parent, name, nil
}

// requireNew refuses an output that exists (a dangling symlink counts) or is the input itself.
func requireNew(dest string, source string) error {
	_, err := os.Lstat(dest)
	switch {
	case err == nil:
		return errors.New("output must be a new non-colliding path")
	case errors.Is(err, os.ErrNotExist), errors.Is(err, syscall.ENOTDIR):
	default:
		return osError(err, dest)
	}
	if source == dest {
		return errors.New("output must be a new non-colliding path")
	}
	return nil
}

// stageFile copies source into the stage under a logical name and returns the source and staged identities.
func (j *job) stageFile(source, target, logical string, mode os.FileMode) (fsx.Record, fsx.Record, error) {
	return fsx.StageFile(source, target, logical, mode, fsx.NoLimit)
}

// executable resolves a trusted executable: the PATH-selected one, or the configured override when it is the
// same file.
func (j *job) executable(name, configuredKey, search string) (string, fsx.Record, error) {
	var configured *string
	if v := j.s.Env(configuredKey); v != "" {
		configured = &v
	}
	host := adapter.DefaultHost(j.d.uid, j.s.Cwd)
	return adapter.Executable(host, name, configured, search)
}
