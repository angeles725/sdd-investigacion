package secretscan

import (
	"bytes"
	"io"
	"regexp"
	"sort"
	"strconv"
)

// Commit objects: a secret typed into a commit message, or into an author, committer or extra header field, is never
// removed by redacting content. The raw objects are read with `rev-list HEAD | cat-file --batch`, which (unlike
// `git log`) is immune to i18n.logOutputEncoding and i18n.commitEncoding: it returns the bytes as stored.

var missingObject = regexp.MustCompile(`(?m)^[0-9a-f]{40}(?:[0-9a-f]{24})? missing$`)

// scanCommits returns the line numbers of the batch stream that hold a high-confidence match, ascending and unique.
// The stream is the legacy one ("<sha> commit <size>", the object, a LF, for each commit), so the numbers agree.
func (s *session) scanCommits() ([]int, *stop) {
	rl, err := s.git.Start(s.abs, nil, "--no-replace-objects", "rev-list", "HEAD")
	if err != nil {
		return nil, s.fail(rcDegraded, "DEGRADED: rev-list|cat-file commit scan failed (rc=127 127) — commit scan incomplete")
	}
	revs, _ := io.ReadAll(rl.Stdout())
	rcRev := rl.Wait()
	cf, err := s.git.Start(s.abs, bytes.NewReader(revs), "--no-replace-objects", "cat-file", "--batch")
	if err != nil {
		return nil, s.fail(rcDegraded, "DEGRADED: rev-list|cat-file commit scan failed (rc="+strconv.Itoa(rcRev)+" 127) — commit scan incomplete")
	}
	stream, _ := io.ReadAll(cf.Stdout())
	rcCat := cf.Wait()
	if rcRev != 0 || rcCat != 0 {
		return nil, s.fail(rcDegraded, "DEGRADED: rev-list|cat-file commit scan failed (rc="+strconv.Itoa(rcRev)+" "+strconv.Itoa(rcCat)+") — commit scan incomplete")
	}
	if missingObject.Match(stream) {
		return nil, s.fail(rcDegraded, "DEGRADED: cat-file --batch reported missing commit object(s) — commit scan incomplete")
	}
	seen := map[int]bool{}
	var lines []int
	for _, h := range scanHC(stream, false) {
		if !seen[h.Line] {
			seen[h.Line] = true
			lines = append(lines, h.Line)
		}
	}
	sort.Ints(lines)
	return lines, nil
}
