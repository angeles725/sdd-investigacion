// Package place puts a downloaded part file at its destination under the overwrite policy of `fetch-doc`
// ("evidence does not die"): a destination that exists is REFUSED (exit 4) unless --replace, a symlinked one is
// ALWAYS refused (exit 5), and with --replace the old bytes are KEPT under a versioned name before the new ones
// are installed. Both refusals happen before any download, so they cost no network and change nothing.
package place

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// Exit codes of the refusals (the script's documented contract).
const (
	ExitFailure     = 1
	ExitExists      = 4
	ExitSymlink     = 5
	versionedSHALen = 12
)

// Placer installs files under one sources directory.
type Placer struct {
	// SDir is TARGET/sources; the File cell of a row is the path relative to it.
	SDir    string
	Replace bool
	Err     io.Writer
	// Hook, when not nil, is called at named points (the test seam: "install").
	Hook func(point string)
}

// Rel is the File cell for dest: its path relative to SDir.
func (p *Placer) Rel(dest string) string { return strings.TrimPrefix(dest, p.SDir+"/") }

// Preflight refuses a symlinked destination (exit 5) and, unless --replace was given, an existing one (exit 4).
// It returns 0 when the destination is free to be written.
func (p *Placer) Preflight(dest string) int {
	if isLink(dest) {
		fmt.Fprintf(p.Err, "fetch-doc: REFUSED: destination is a symlink: %s — remove it or choose another name; nothing fetched\n", dest)
		return ExitSymlink
	}
	if exists(dest) && !p.Replace {
		fmt.Fprintf(p.Err, "fetch-doc: REFUSED: destination already exists: %s — re-run with --replace to keep the old bytes under a versioned name; nothing fetched\n", dest)
		return ExitExists
	}
	return 0
}

// Install moves part over dest. When dest exists (only reachable with --replace) and its bytes differ, the old
// bytes are first kept under a versioned name and their row retargeted. same is true (and part is dropped) when
// the bytes are identical AND already registered: no new row is due. A non-zero code is the exit status; the
// refusal message is already written.
func (p *Placer) Install(part, dest string) (same bool, code int) {
	p.hook("install")
	rel := p.Rel(dest)
	// Preflight ran BEFORE the download, so a concurrent run on the same name may have landed a file (or a
	// symlink) since: re-check.
	if isLink(dest) {
		fmt.Fprintf(p.Err, "fetch-doc: REFUSED: destination became a symlink during the download: %s; nothing installed\n", dest)
		return false, ExitSymlink
	}
	if p.Replace && exists(dest) {
		same, code = p.archive(part, dest, rel)
		if same || code != 0 {
			return same, code
		}
	}
	if !p.Replace {
		// The install is EXCLUSIVE: a hard link fails atomically when dest exists, so a file that appears between
		// the re-check above and here still cannot be overwritten.
		if err := os.Link(part, dest); err == nil {
			_ = os.Remove(part)
			return false, 0
		}
		if exists(dest) || isLink(dest) {
			fmt.Fprintf(p.Err, "fetch-doc: REFUSED: destination appeared during the download: %s — re-run with --replace to keep the old bytes under a versioned name; nothing installed\n", dest)
			return false, ExitExists
		}
		// The link failed for another reason (a filesystem without hard links): fall through to the plain move.
	}
	if err := os.Rename(part, dest); err != nil {
		_ = os.Remove(part)
		fmt.Fprintf(p.Err, "fetch-doc: could not move download into place: %s\n", dest)
		return false, ExitFailure
	}
	return false, 0
}

func (p *Placer) hook(point string) {
	if p.Hook != nil {
		p.Hook(point)
	}
}

func exists(path string) bool { _, err := os.Stat(path); return err == nil }

func isLink(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode()&os.ModeSymlink != 0
}
