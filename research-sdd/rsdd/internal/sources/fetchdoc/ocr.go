package fetchdoc

import (
	"context"
	"os"
	"path/filepath"
	"sort"
)

// ocrDPI is the rasterisation resolution handed to pdftoppm.
const ocrDPI = "300"

// ocr is `fetch-doc ocr <pdf>`: rasterise a scanned PDF (pdftoppm) and print the text of every page (tesseract) on
// stdout, in page order. It registers nothing and ignores --replace.
func (x *exe) ocr(r request) int {
	pdf := r.arg(0)
	if pdf == "" {
		return x.usageError(usageOCR, "missing pdf")
	}
	if !x.d.have("tesseract") {
		x.printf("tesseract not installed\n")
		return exitMissing
	}
	dir, err := os.MkdirTemp(x.d.TmpDir, "tmp.")
	if err != nil {
		x.printf("fetch-doc: cannot create a temporary directory in %s: %v\n", x.d.TmpDir, err)
		return exitFailure
	}
	defer os.RemoveAll(dir)
	ctx := context.Background()
	if x.d.Run.Run(ctx, []string{"pdftoppm", "-r", ocrDPI, "-png", pdf, dir + "/ocr"}, nil, nil) != 0 {
		x.printf("pdftoppm failed\n")
		return exitMissing
	}
	pages, _ := filepath.Glob(dir + "/ocr-*.png")
	sort.Strings(pages)
	if len(pages) == 0 {
		x.printf("fetch-doc: pdftoppm produced no pages for %s; nothing to read\n", pdf)
		return exitFailure
	}
	for i, page := range pages {
		if rc := x.d.Run.Run(ctx, []string{"tesseract", page, "stdout"}, x.d.Out, nil); rc != 0 {
			x.printf("fetch-doc: tesseract failed on page %d of %d (exit %d); the text above is incomplete\n", i+1, len(pages), rc)
			return exitFailure
		}
	}
	return 0
}
