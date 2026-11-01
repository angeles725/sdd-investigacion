package adapter

import (
	"os"
	"strings"
)

// PrivateFS is adapter_core.PRIVATE_FS: the whitelist of Linux filesystem
// types accepted as private. Anything else, unknown types included, is
// rejected (fail closed).
var PrivateFS = map[string]bool{
	"btrfs": true, "ext2": true, "ext3": true, "ext4": true, "f2fs": true, "jfs": true, "nilfs2": true,
	"overlay": true, "ramfs": true, "reiserfs": true, "tmpfs": true, "ubifs": true, "xfs": true, "zfs": true,
}

// HostMountinfo reads /proc/self/mountinfo, the default Python reads.
func HostMountinfo() (string, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	return string(b), err
}

func malformed(detail, line string) error {
	return &Error{Msg: "malformed mountinfo line" + detail + ": " + pyRepr(line)}
}

// RequirePrivate is adapter_core.require_private: the deepest mount point
// containing path (by lexical path components, first wins on a tie) must be a
// PrivateFS type. mountinfo is the /proc/self/mountinfo text; a malformed line
// is an Error, never a panic.
func RequirePrivate(path, mountinfo string) error {
	target := pyParts(path)
	selDepth, selFS := -1, ""
	for _, line := range pySplitlines(mountinfo) {
		left, right, ok := strings.Cut(line, " - ")
		if !ok {
			return malformed(" (missing ' - ' separator)", line)
		}
		lf := pyFields(left)
		if len(lf) < 5 {
			return malformed(" (too few left fields)", line)
		}
		enc := strings.ReplaceAll(lf[4], `\040`, " ")
		enc = strings.ReplaceAll(enc, `\011`, "\t")
		enc = strings.ReplaceAll(enc, `\134`, `\`)
		mount := pyParts(enc)
		rf := pyFields(right)
		if len(rf) == 0 {
			return malformed(" (empty right side)", line)
		}
		if !underMount(target, mount) {
			continue
		}
		if len(mount) > selDepth {
			selDepth, selFS = len(mount), rf[0]
		}
	}
	if selDepth == -1 {
		return &Error{Msg: "output path is under no known mount point"}
	}
	if !PrivateFS[selFS] {
		return &Error{Msg: "output must reside on a Linux-private filesystem"}
	}
	return nil
}

// underMount is Path.relative_to(mount) succeeding: mount's parts are a
// prefix of path's. An empty (relative) mount contains only relative paths.
func underMount(path, mount []string) bool {
	if len(mount) == 0 {
		return len(path) == 0 || !strings.HasPrefix(path[0], "/")
	}
	if len(mount) > len(path) {
		return false
	}
	for i, m := range mount {
		if path[i] != m {
			return false
		}
	}
	return true
}
