package java

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

// stageMarker is what a stage directory managed by this command holds in .corroborate-java-stage: only a
// directory carrying it is ever removed on a later run.
const stageMarker = "research-sdd corroborate-java staging v1\n"

// removeTree is the seam a test uses to interrupt an overwrite between the exchange and the cleanup.
var removeTree = removePrivateTree

// removePrivateTree is remove_private_tree: the read-only trusted-tools directory is made writable, then the
// whole stage goes.
func removePrivateTree(path string) error {
	trusted := filepath.Join(path, "trusted-tools")
	if fi, err := os.Lstat(trusted); err == nil && fi.IsDir() {
		_ = os.Chmod(trusted, 0o700)
	}
	return os.RemoveAll(path)
}

// prepareStage is prepare_stage: a fresh private stage next to the destination. A leftover stage of this command
// is cleared; anything else at that path is refused.
func prepareStage(destination string) (string, error) {
	stage := filepath.Join(filepath.Dir(destination), "."+filepath.Base(destination)+".stage")
	if _, err := os.Lstat(stage); err == nil {
		marker := filepath.Join(stage, ".corroborate-java-stage")
		sfi, serr := os.Lstat(stage)
		mfi, merr := os.Lstat(marker)
		body, _ := os.ReadFile(marker)
		if serr != nil || sfi.Mode()&os.ModeSymlink != 0 || !sfi.IsDir() ||
			merr != nil || mfi.Mode()&os.ModeSymlink != 0 || !mfi.Mode().IsRegular() || !bytes.Equal(body, []byte(stageMarker)) {
			return "", fail("staging path exists and is not managed by corroborate-java")
		}
		if err := removePrivateTree(stage); err != nil {
			return "", osFailure(err, stage)
		}
	}
	if err := os.Mkdir(stage, 0o700); err != nil {
		return "", osFailure(err, stage)
	}
	if err := os.WriteFile(filepath.Join(stage, ".corroborate-java-stage"), []byte(stageMarker), 0o666); err != nil {
		return stage, osFailure(err, "")
	}
	return stage, nil
}

// publish is publish: the stage becomes the destination atomically. A new destination is a no-replace rename; an
// existing one (with --overwrite) is exchanged with the stage so it stays visible throughout, then the old tree
// is removed.
func publish(stage, destination string, overwrite bool) error {
	if isSymlink(destination) {
		return fail("output root must not be a symlink")
	}
	exists := pathExists(destination)
	if exists && !overwrite {
		return fail("output root exists; pass --overwrite")
	}
	parent := filepath.Dir(destination)
	if exists {
		if fi, err := os.Stat(destination); err != nil || !fi.IsDir() {
			return fail("output root must be a directory")
		}
		if err := fsx.RenameExchange(stage, destination); err != nil {
			return publishFailure(err, destination)
		}
		if err := fsx.SyncDir(parent); err != nil {
			return osFailure(err, parent)
		}
		if err := removeTree(stage); err != nil {
			return osFailure(err, stage)
		}
		return syncParent(parent)
	}
	if err := fsx.RenameNoReplace(stage, destination); err != nil {
		return publishFailure(err, destination)
	}
	return syncParent(parent)
}

func syncParent(parent string) error {
	if err := fsx.SyncDir(parent); err != nil {
		return osFailure(err, parent)
	}
	return nil
}

func publishFailure(err error, destination string) error {
	if errors.Is(err, fsx.ErrUnavailable) {
		return fail("atomic publication is unavailable on this platform")
	}
	return osFailure(err, destination)
}
