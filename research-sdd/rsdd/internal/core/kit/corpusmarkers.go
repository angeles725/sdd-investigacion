package kit

import (
	"os"
	"path"
	"strings"
)

// Port of lib/corpus-markers.sh: does a directory carry a recognised corpus marker? The bash helper stays in
// the tree for research-sdd-init.sh, which sources it; this is the Go side for verify registry and later ports.

// CorpusHasMarker is corpus_has_marker: true when dir exists and carries, at its OWN root (no descent), INDEX.md,
// CATALOG.md, or any RESEARCH-STATE*.md that is not a *.template.md. A missing or non-directory dir is false,
// never an error. `[ -e ]` follows symlinks, so a dangling INDEX.md link is not a marker, and a directory named
// like a marker counts as one (the shell tests existence only).
func CorpusHasMarker(dir string) bool {
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return false
	}
	for _, m := range []string{"INDEX.md", "CATALOG.md"} {
		if _, err := os.Stat(dir + "/" + m); err == nil {
			return true
		}
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return false // an unlistable directory: the shell glob stays literal and `[ -e ]` on it fails
	}
	for _, e := range ents {
		n := e.Name()
		if ok, _ := path.Match("RESEARCH-STATE*.md", n); !ok || strings.HasSuffix(n, ".template.md") {
			continue
		}
		if _, err := os.Stat(dir + "/" + n); err == nil {
			return true
		}
	}
	return false
}

// CorpusMarkerPresent is corpus_marker_present: true when ANY candidate root carries a marker.
func CorpusMarkerPresent(roots ...string) bool {
	for _, r := range roots {
		if CorpusHasMarker(r) {
			return true
		}
	}
	return false
}
