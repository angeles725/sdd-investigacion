package fetchdoc

import (
	"context"
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/download"
)

// defaultSub is the sources sub-directory of `doc` when none is given.
const defaultSub = "datasheets"

// doc is `fetch-doc doc <url> <target-dir> [datasheets|manuals] [name]`: download a document into
// TARGET/sources/<sub>/<name> and register it in SOURCES.md.
func (x *exe) doc(r request) int {
	url, tdir := r.arg(0), r.arg(1)
	sub, name := r.arg(2), r.arg(3)
	if sub == "" {
		sub = defaultSub
	}
	if name == "" {
		name = baseName(url)
	}
	switch {
	case url == "":
		return x.usageError(usageDoc, "missing url")
	case tdir == "":
		return x.usageError(usageDoc, "missing target-dir")
	}
	for _, why := range []string{checkURL(url), checkSub(sub), checkName(name)} {
		if why != "" {
			return x.usageError(usageDoc, "%s", why)
		}
	}
	if code := x.needDownloader(); code != 0 {
		return code
	}
	sdir := tdir + "/sources"
	if code := x.mkdir(sdir + "/" + sub); code != 0 {
		return code
	}
	dest := sdir + "/" + sub + "/" + name
	pl := x.placer(sdir, r.replace, "DEST="+dest)
	part := x.fetch.PartPath(dest)
	defer removeAll(part) // only the PART file: dest may be an already-registered file and is never touched here
	if code := pl.Preflight(dest); code != 0 {
		return code
	}
	pl.SweepStale(sdir+"/"+sub, x.alive())
	effective := ""
	if code := x.track([]string{"DEST=" + dest, "SDIR=" + sdir, "REPLACE=" + boolDigit(r.replace)}, func(ctx context.Context) int {
		var c int
		effective, c = x.fetch.Fetch(ctx, url, dest, true)
		return c
	}); code != 0 {
		return x.asExit(code)
	}
	x.sess.Block() // from here to the written row a signal must not leave new bytes without a row
	same, code := pl.Install(part, dest)
	if code != 0 {
		return code
	}
	sha, err := srcregistry.FileSHA256(dest)
	if err != nil {
		x.printf("fetch-doc: cannot hash %s: %v\n", dest, err)
		return exitFailure
	}
	x.pdfHint(dest)
	if same {
		fmt.Fprintf(x.d.Out, "OK: %s -> %s  (identical bytes already registered; no new row)\n", url, dest)
		return 0
	}
	if code := x.register(sdir, dest, sub, effective, sha); code != 0 {
		return code
	}
	fmt.Fprintf(x.d.Out, "OK: %s -> %s  (sha256 %s…, registered in SOURCES.md)\n", url, dest, sha[:16])
	return 0
}

// asExit maps a stage status to the exit status: a cancelled download is not an exit code of its own.
func (x *exe) asExit(code int) int {
	if code == download.Cancelled {
		if c, ok := x.sess.interrupted(); ok {
			return c
		}
		return exitFailure
	}
	return code
}

// mkdir is `mkdir -p`; a failure is a typed message, not a bare tool error.
func (x *exe) mkdir(dir string) int {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		x.printf("fetch-doc: cannot create %s: %v\n", dir, err)
		return exitFailure
	}
	return 0
}
