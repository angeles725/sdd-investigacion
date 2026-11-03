package corrections

import (
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// maxDepth is find's -maxdepth for both the block files and FOCUSES.md.
const maxDepth = 3

// findFiles is `find <target> -maxdepth 3 -type f -name <match> -not -path '*/.git/*'`: the paths as find prints
// them (the target as given, then "/" and the relative path), in directory order. Unreadable directories are
// skipped silently, as find's 2>/dev/null did. Symlinks are not followed and are not regular files.
func findFiles(target string, match func(name string) bool) []string {
	var out []string
	join := func(dir, name string) string {
		if strings.HasSuffix(dir, "/") {
			return dir + name
		}
		return dir + "/" + name
	}
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			p := join(dir, e.Name())
			if strings.Contains(p, "/.git/") {
				continue
			}
			switch {
			case e.Type().IsRegular():
				if match(e.Name()) {
					out = append(out, p)
				}
			case e.IsDir() && depth < maxDepth:
				walk(p, depth+1)
			}
		}
	}
	walk(target, 1)
	return out
}

// isBlockCandidate is `-name '*.md' -not -name '*.template.md'`.
func isBlockCandidate(name string) bool {
	return strings.HasSuffix(name, ".md") && !strings.HasSuffix(name, ".template.md")
}

// listBlocks is the sorted list of canonical block files under target (the discriminator is core/kit's, the one
// copy of lib/block-files.sh). The sort is bytewise, so the report order does not depend on the caller's locale.
func listBlocks(target string) []string {
	cand := findFiles(target, isBlockCandidate)
	if len(cand) == 0 {
		return nil
	}
	blocks, err := kit.FilterBlockFiles(cand, false, "")
	if err != nil {
		return nil
	}
	sort.Strings(blocks)
	return blocks
}

// blockKey is a block file name split into its focus prefix and its block number (leading zeros removed, at least
// one digit kept). The legacy sed expressions took the LAST `-block<N>`/`-bloque<N>` of the name: the number is
// the digit run after it, the prefix is everything before its dash.
func blockKey(base string) (prefix, num string) {
	for i := len(base) - 1; i >= 0; i-- {
		if base[i] != '-' {
			continue
		}
		rest := base[i+1:]
		switch {
		case strings.HasPrefix(rest, "bloque"):
			rest = rest[len("bloque"):]
		case strings.HasPrefix(rest, "block"):
			rest = rest[len("block"):]
		default:
			continue
		}
		j := 0
		for j < len(rest) && rest[j] >= '0' && rest[j] <= '9' {
			j++
		}
		if j == 0 {
			continue
		}
		return base[:i], trimZeros(rest[:j])
	}
	return "", ""
}

// trimZeros removes leading zeros, keeping one digit.
func trimZeros(d string) string {
	d = strings.TrimLeft(d, "0")
	if d == "" {
		return "0"
	}
	return d
}

// reFocusPrefix is the `<prefix>-block<N|digits>` token of a FOCUSES.md cell.
var reFocusPrefix = regexp.MustCompile(`([A-Za-z0-9][A-Za-z0-9._-]*)-(block|bloque)(N|[0-9]+)`)

// readFocuses maps focus slug -> block prefix from every FOCUSES.md under target (depth <= 3, sorted). Row shape:
// | `slug` | status | state | `prefix-blockN.md` | question |   (the prefix is the `<prefix>-blockN` token of any
// cell after the slug). A later row of the same slug wins.
func readFocuses(target string, read func(string) (string, bool)) map[string]string {
	m := map[string]string{}
	files := findFiles(target, func(n string) bool { return n == "FOCUSES.md" })
	sort.Strings(files)
	for _, fm := range files {
		src, ok := read(fm)
		if !ok {
			continue
		}
		for _, line := range kit.SplitLines(src) {
			if !isTableLine(line) {
				continue
			}
			cols := splitReadFields(line, '|')
			if len(cols) < 3 {
				continue
			}
			slug := strings.ToLower(strings.NewReplacer("`", "", "*", "", " ", "", "\t", "", "\n", "", "\v", "", "\f", "", "\r", "").Replace(cols[1]))
			if slug == "" {
				continue
			}
			for _, cell := range cols[2:] {
				if mm := reFocusPrefix.FindStringSubmatch(cell); mm != nil {
					m[slug] = mm[1]
					break
				}
			}
		}
	}
	return m
}

// isTableLine is `grep -E '^[[:space:]]*\|'`.
func isTableLine(l string) bool {
	return strings.HasPrefix(strings.TrimLeft(l, " \t\n\v\f\r"), "|")
}

// splitReadFields is bash's `IFS='|' read -r -a cols`: a non-whitespace separator, an empty field between two
// separators, and no trailing empty field.
func splitReadFields(line string, sep byte) []string {
	var f []string
	start := 0
	for i := 0; i < len(line); i++ {
		if line[i] == sep {
			f = append(f, line[start:i])
			start = i + 1
		}
	}
	if start < len(line) {
		f = append(f, line[start:])
	}
	return f
}
