// Package kit ports the research-sdd kit's path-derivation libraries to Go with byte parity against the bash
// originals (toolbelt/lib/target-paths.sh and toolbelt/lib/state-files.sh in this unit; block-files.sh,
// focus-prefix.sh and the hook-kit-run.sh kit-resolution order are deferred, see DEFERRED.md).
//
// Design rules:
//   - The logic never reads the process environment. Callers inject a Getenv func (the way niagara-go injects
//     Stdio), so a test pins RESEARCH_HOME and HOME explicitly.
//   - Filesystem roots are plain path arguments; nothing is resolved against hidden state. Relative paths resolve
//     against an explicit cwd argument that the caller takes from the cli boundary (Stdio.Cwd), exactly like the
//     bash `cd -P` resolves them against its `pwd`.
//   - Sorting is C-locale (bytewise). The bash libs call plain `sort -u` (see DEFERRED.md, finding F3), so byte
//     parity is defined against LC_ALL=C.
//   - absent-input, empty-input and no-match are distinct typed outcomes (kit CLAUDE.md section 7); a degraded
//     read is an error, never an empty result.
//   - TARGETS.md and every target directory are only ever read or stat-ed (section 8).
package kit

import (
	"errors"
	"os"
	"strings"
)

// Getenv looks an environment variable up. There is no default; pass os.Getenv at the process edge.
type Getenv func(key string) string

// Typed sentinels. Match with errors.Is.
var (
	// ErrUsage: the caller passed no usable argument (bash rc 1 "called with no argument").
	ErrUsage = errors.New("kit: usage")
	// ErrAbsentInput: the file or directory does not exist or is not the expected kind.
	ErrAbsentInput = errors.New("kit: absent input")
	// ErrUnreadable: the input exists but cannot be read. Bash silently returns an empty list here
	// (target_paths_all on a mode-000 file exits 0 with no output); Go reports it (finding F2).
	ErrUnreadable = errors.New("kit: unreadable input")
)

// cLess is bytewise comparison, the order of `LC_ALL=C sort`.
func cLess(a, b string) bool { return strings.Compare(a, b) < 0 }

// readRegular reads path the way `[ -f path ]` plus a successful read does: a missing path or a non-regular
// file is ErrAbsentInput, a failed read is ErrUnreadable.
func readRegular(path string) (string, error) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return "", ErrAbsentInput
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", ErrUnreadable
	}
	return string(b), nil
}
