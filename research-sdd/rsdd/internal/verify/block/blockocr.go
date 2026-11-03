package block

import (
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Section 4 of verify-block: the OCR-provenance flag. A [CERT-doc] citation sourced from an OCR'd (scanned) PDF is
// lossy; sources/extracted/*.md files tagged `reliability: ocr-lossy` (or "extracted via OCR") are cross-referenced
// with the block, and every block line naming the PDF, the extract or the loose key is flagged for re-verification.
// Advisory: the exit code never changes.

var vbOCRTag = vbRe(`(?i)reliability:[[:space:]]*ocr-lossy|extracted via OCR`)

func (b *blockRun) sectionOCR() {
	b.echo("-- OCR-provenance flag (reliability: ocr-lossy) --")
	dir := b.target + "/sources/extracted"
	lossy := false
	if b.fs.IsDir(dir) {
		for _, ext := range b.findDirMarkdown(dir) {
			if !b.fs.IsFile(ext) {
				continue
			}
			src, err := b.fs.Read(ext)
			if err != nil || !vbOCRTag.MatchString(string(src)) {
				continue
			}
			name := shellx.BaseName(ext)
			stem := strings.TrimSuffix(name, ".md")
			parts := strings.SplitN(stem, "-", 3)
			loose := strings.Join(parts[:min(len(parts), 2)], "-") // cut -d- -f1-2
			pdfBase := ""
			if pdf := sourcePDF(shellx.RecordLines(string(src))); pdf != "" {
				pdfBase = vbStripExt(shellx.BaseName(pdf))
			}
			var hits []string
			for _, tok := range []string{pdfBase, stem, loose} {
				if tok == "" {
					continue
				}
				if strings.HasPrefix(tok, "-") { // GNU grep reads the token as an option (exit 1 for a bad one): nothing found
					continue
				}
				for i, l := range b.lines {
					if strings.Contains(l, tok) {
						hits = append(hits, strconv.Itoa(i+1)+":"+l)
					}
				}
			}
			hits = dedupeByLine(hits)
			if len(hits) > 0 {
				b.echo("   OCR!    lines citing OCR-lossy '%s' — re-verify numbers/quotes/serials vs page image:", stem)
				for _, h := range hits {
					b.echo("           %s", h)
				}
				lossy = true
			}
		}
	}
	if !lossy {
		b.echo("   (none — no citation traces to an OCR-lossy extract)")
	}
}

// sourcePDF is `awk -F': ' '/source_pdf:/{print $2; exit}'`.
func sourcePDF(lines []string) string {
	for _, l := range lines {
		if strings.Contains(l, "source_pdf:") {
			if f := strings.Split(l, ": "); len(f) > 1 {
				return f[1]
			}
			return ""
		}
	}
	return ""
}

// dedupeByLine is `sort -t: -k1n -u`: ascending by line number, the first line seen for a number kept.
func dedupeByLine(hits []string) []string {
	first := map[int]string{}
	var ns []int
	for _, s := range hits {
		n, _ := strconv.Atoi(s[:strings.Index(s, ":")])
		if _, ok := first[n]; !ok {
			first[n] = s
			ns = append(ns, n)
		}
	}
	sort.Ints(ns)
	var out []string
	for _, n := range ns {
		out = append(out, first[n])
	}
	return out
}

// findDirMarkdown is `find DIR -maxdepth 1 -name '*.md'` in byte order (find's own order depends on the filesystem).
func (b *blockRun) findDirMarkdown(dir string) []string {
	f, err := os.Open(b.fs.At(dir))
	if err != nil {
		return nil
	}
	names, _ := f.Readdirnames(-1)
	f.Close()
	sort.Strings(names)
	var out []string
	for _, n := range names {
		if strings.HasSuffix(n, ".md") {
			out = append(out, joinFind(dir, n))
		}
	}
	return out
}
