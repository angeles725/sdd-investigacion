package corpus

import (
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// archiveBlockFilter is `block_file_filter` (no prefix) over paths: those whose basename is a canonical block file.
// No match and no input both yield an empty list; the archive treats them alike (a count of 0).
func archiveBlockFilter(paths []string) []string {
	out, err := kit.FilterBlockFiles(paths, false, "")
	if err != nil {
		return nil
	}
	return out
}

// archiveFocusPrefix is `derive_focus_prefix <state-file>`.
func archiveFocusPrefix(state string) (string, error) {
	p, err := kit.DeriveFocusPrefix(state)
	return p.Value, err
}

// archiveCorpusBlocks is `find corpus -maxdepth 1 -type f -name '*.md' | block_file_filter`.
func archiveCorpusBlocks(corpus string) []string {
	var cand []string
	for _, p := range archiveFind(corpus, 1) {
		if p == corpus {
			continue
		}
		st, err := os.Lstat(p)
		if err != nil || !st.Mode().IsRegular() || !strings.HasSuffix(p, ".md") {
			continue
		}
		cand = append(cand, p)
	}
	return archiveBlockFilter(cand)
}
