package show

import (
	"os"
	"sort"
	"strings"
)

// Port of contra_ledgers and count_open_contra: the corpus-level CONTRADICTIONS ledgers (METHODOLOGY §14), counted
// together and never head-1-dropped.

// contraLedgers is `find "$corpus" -maxdepth 1 -name 'CONTRADICTIONS*.md' | sort`, as paths under the corpus.
func (c *ctx) contraLedgers() []string {
	ents, err := os.ReadDir(c.abs(c.corpus))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		n := e.Name()
		if len(n) >= len("CONTRADICTIONS.md") && strings.HasPrefix(n, "CONTRADICTIONS") && strings.HasSuffix(n, ".md") {
			out = append(out, strings.TrimSuffix(c.corpus, "/")+"/"+n)
		}
	}
	sort.Strings(out)
	return out
}

// countOpenContra is count_open_contra: rows whose 4th cell is exactly "open" (ASCII case-blind), over all files.
// A file that cannot be read contributes none (awk's complaint on stderr is not reproduced).
func (c *ctx) countOpenContra(files []string) int {
	n := 0
	for _, f := range files {
		b, err := os.ReadFile(c.abs(f))
		if err != nil {
			continue
		}
		for _, line := range splitLines(string(b)) {
			if openContraRow(line) {
				n++
			}
		}
	}
	return n
}

// openContraRow reads one line as the awk does: a table row whose 4th cell is "open". `\|` is cell text, so it
// is masked before the split and a masked cell can never equal "open".
func openContraRow(line string) bool {
	line = trimBlanks(line)
	if !strings.Contains(line, "|") {
		return false
	}
	line = strings.ReplaceAll(line, `\|`, "\x01") // GFM-EP-CONTRA
	line = strings.TrimSuffix(strings.TrimPrefix(line, "|"), "|")
	cells := strings.Split(line, "|")
	return len(cells) >= 4 && lowerASCII(trimBlanks(cells[3])) == "open"
}
