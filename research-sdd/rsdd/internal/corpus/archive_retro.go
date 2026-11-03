package corpus

import (
	"bytes"
	"os"
	"regexp"
	"sort"
	"strings"
)

// Ports of the three retro helpers of toolbelt/lib/retro-status.sh the archive uses (retro_is_excluded,
// retro_review_status, retro_has_bare_marker) and of the `find` expressions that list retros.

var (
	archiveReCommentLine = regexp.MustCompile(`^[[:space:]]*<!--`)
	archiveReBlankLine   = regexp.MustCompile(`^[[:space:]]*$`)
	archiveReStatusMark  = regexp.MustCompile(`(?i)<!--[[:space:]]*review-status:`)
	archiveReStatusWord  = regexp.MustCompile(`(?i)<!--[[:space:]]*review-status:[[:space:]]*[a-z]+`)
	archiveReExclude     = regexp.MustCompile(`(?i)^[[:space:]]*<!--[[:space:]]*kit-retro:[[:space:]]*exclude[[:space:]]*-->[[:space:]]*$`)
	archiveReBare        = regexp.MustCompile(`(?i)^[[:space:]]*review-status:`)
)

// archiveReadRetro is `_retro_status_strip_bom f` for a regular file: its lines with a leading UTF-8 BOM removed.
// ok is false for a file that is not regular or cannot be read (the bash helpers then print nothing).
func archiveReadRetro(f string) (lines []string, ok bool) {
	st, err := os.Stat(f)
	if err != nil || !st.Mode().IsRegular() {
		return nil, false
	}
	b, err := os.ReadFile(f)
	if err != nil {
		return nil, true
	}
	b = bytes.TrimPrefix(b, []byte{0xef, 0xbb, 0xbf})
	s := string(b)
	if s == "" {
		return nil, true
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n"), true
}

// archiveLeadingBlock is the awk filter of the helpers: comment lines of the leading block, blank lines skipped, the
// first other line ends it.
func archiveLeadingBlock(lines []string) []string {
	var out []string
	for _, l := range lines {
		switch {
		case archiveReCommentLine.MatchString(l):
			out = append(out, l)
		case archiveReBlankLine.MatchString(l):
		default:
			return out
		}
	}
	return out
}

// archiveRetroExcluded is retro_is_excluded: the leading block carries `<!-- kit-retro: exclude -->`.
func archiveRetroExcluded(f string) bool {
	lines, ok := archiveReadRetro(f)
	if !ok {
		return false
	}
	for _, l := range archiveLeadingBlock(lines) {
		if archiveReExclude.MatchString(l) {
			return true
		}
	}
	return false
}

// archiveRetroStatus is retro_review_status: the lower-cased word after `review-status:` on the first marker line of the
// leading block, or "" (no marker, or a marker without a word).
func archiveRetroStatus(f string) string {
	lines, ok := archiveReadRetro(f)
	if !ok {
		return ""
	}
	for _, l := range archiveLeadingBlock(lines) {
		if !archiveReStatusMark.MatchString(l) {
			continue
		}
		m := archiveReStatusWord.FindString(l)
		if m == "" {
			return ""
		}
		i := strings.LastIndex(m, ":")
		return strings.ToLower(strings.TrimLeft(m[i+1:], " \t\n\v\f\r"))
	}
	return ""
}

// archiveRetroBareMarker is retro_has_bare_marker: `review-status:` as bare text in the first ten lines.
func archiveRetroBareMarker(f string) bool {
	lines, ok := archiveReadRetro(f)
	if !ok {
		return false
	}
	if len(lines) > 10 {
		lines = lines[:10]
	}
	for _, l := range lines {
		if archiveReBare.MatchString(l) {
			return true
		}
	}
	return false
}

// archiveFind lists root and what lies below it down to maxdepth like `find root -maxdepth N` (default -P): files,
// directories and symlinks alike, never following a symlink (the start point included), unreadable directories skipped.
func archiveFind(root string, maxdepth int) []string {
	out := []string{root}
	st, err := os.Lstat(root)
	if err != nil || !st.IsDir() {
		return out
	}
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			p := dir + "/" + e.Name()
			if strings.HasSuffix(dir, "/") {
				p = dir + e.Name()
			}
			out = append(out, p)
			if e.IsDir() && depth < maxdepth {
				walk(p, depth+1)
			}
		}
	}
	if maxdepth >= 1 {
		walk(root, 1)
	}
	return out
}

// archiveRetroPathMatch is find's `-path '*/retros/*.md'`: `*` also matches `/`, so any path with a "/retros/"
// followed by something that ends in ".md" qualifies (the directories above the corpus count too).
func archiveRetroPathMatch(p string) bool {
	if !strings.HasSuffix(p, ".md") {
		return false
	}
	i := strings.Index(p, "/retros/")
	return i >= 0 && i+len("/retros/")+len(".md") <= len(p)
}

// archiveIndexName is find's `-iname '*index*.md'` on a basename.
func archiveIndexName(base string) bool {
	l := strings.ToLower(base)
	i := strings.Index(l, "index")
	return i >= 0 && strings.HasSuffix(l, ".md") && i+len("index")+len(".md") <= len(l)
}

// archiveRetroPaths is `find corpus target -maxdepth 2 -path '*/retros/*.md' | sort -u` (byte order).
func archiveRetroPaths(corpus, target string, skipIndex bool) []string {
	seen := map[string]bool{}
	var out []string
	for _, root := range []string{corpus, target} {
		for _, p := range archiveFind(root, 2) {
			if !archiveRetroPathMatch(p) {
				continue
			}
			if skipIndex && archiveIndexName(p[strings.LastIndex(p, "/")+1:]) {
				continue
			}
			if !seen[p] {
				seen[p] = true
				out = append(out, p)
			}
		}
	}
	sort.Strings(out)
	return out
}
