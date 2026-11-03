package corpus

import "time"

// archiveHooks are the seams of `rsdd corpus archive`: each one defaults to the real filesystem operation and exists so
// a test can reproduce a failure the retired bash suite produced with a PATH shim or a stubbed library.
type archiveHooks struct {
	// touch sets the access and modification time of the INDEX file (the bash `touch`).
	touch func(path string, t time.Time) error
	// walk lists every regular file under root, pruning `.git` directories, as `find root ( -name .git -type d )
	// -prune -o -type f -print0` does. perm counts unreadable directories (find's "Permission denied" lines); an error
	// means the list is not computable.
	walk func(root string) (paths []string, perm int, err error)
	// phys is `cd -P p && pwd -P`.
	phys func(p string) (string, bool)
	// listState is list_state_files over dir.
	listState func(dir string) ([]string, error)
}
