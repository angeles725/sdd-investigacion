package fetchdoc

import (
	"bytes"
	"context"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// utcLayout is the Date (UTC) cell format: `date -u +%FT%TZ`.
const utcLayout = "2006-01-02T15:04:05Z"

// register adds the row of dest to SOURCES.md of sdir: the File cell is the path relative to sdir, the sha256 cell
// the FULL 64 hex (verify-sources recomputes and enforces it; a truncated cell would let a tampered snapshot
// pass), the Origin cell the registered URL with any "|" percent-encoded so the row keeps its columns.
func (x *exe) register(sdir, dest, kind, origin, sha string) int {
	row := srcregistry.FormatRow(strings.TrimPrefix(dest, sdir+"/"), kind, srcregistry.SafeCell(origin), x.d.Now().UTC().Format(utcLayout), sha)
	if err := srcregistry.Append(sdir, row); err != nil {
		x.printf("fetch-doc: cannot update %s: %v\n", srcregistry.SourcesFile, err)
		return exitFailure
	}
	return 0
}

// pdfHint recommends the page-anchored extraction tool when the saved file is a PDF: a flat pdftotext dump has no
// page anchors, so blocks cannot cite page/section from it (METHODOLOGY.md section 5). It asks file(1) like the
// script did and, when file(1) is not installed, reads the %PDF- magic instead of staying silent.
func (x *exe) pdfHint(dest string) {
	if !x.isPDF(dest) {
		return
	}
	x.printf("hint: PDF saved. For page-anchored citations (§5), run: extract-pdf.sh \"%s\"  (a flat pdftotext dump has no page anchors and must not be cited).\n", dest)
}

func (x *exe) isPDF(dest string) bool {
	if x.d.have("file") {
		var out bytes.Buffer
		x.d.Run.Run(context.Background(), []string{"file", "-b", dest}, &out, nil)
		return strings.Contains(strings.ToLower(out.String()), "pdf")
	}
	return hasPDFMagic(dest)
}
