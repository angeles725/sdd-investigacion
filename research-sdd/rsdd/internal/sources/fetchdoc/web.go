package fetchdoc

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/slug"
)

// web is `fetch-doc web <url> <target-dir>`: download a page, convert it to markdown (pandoc, else a plain copy)
// and register the snapshot under TARGET/sources/web-snapshots/<slug>.md.
func (x *exe) web(r request) int {
	url, tdir := r.arg(0), r.arg(1)
	switch {
	case url == "":
		return x.usageError(usageWeb, "missing url")
	case tdir == "":
		return x.usageError(usageWeb, "missing target-dir")
	}
	if why := checkURL(url); why != "" {
		return x.usageError(usageWeb, "%s", why)
	}
	if code := x.needDownloader(); code != 0 {
		return code
	}
	sdir := tdir + "/sources"
	if code := x.mkdir(sdir + "/web-snapshots"); code != 0 {
		return code
	}
	dest := sdir + "/web-snapshots/" + slug.Web(url) + ".md"
	pl := x.placer(sdir, r.replace, "DEST="+dest)
	// Refuse BEFORE the temporary file exists, so a refusal leaves nothing behind.
	if code := pl.Preflight(dest); code != 0 {
		return code
	}
	pl.SweepStale(sdir+"/web-snapshots", x.alive())
	html, err := os.CreateTemp(x.d.TmpDir, "tmp.")
	if err != nil {
		x.printf("fetch-doc: cannot create a temporary file in %s: %v\n", x.d.TmpDir, err)
		return exitFailure
	}
	_ = html.Close()
	htmlPath, wpart := html.Name(), x.fetch.PartPath(dest)
	defer removeAll(htmlPath, x.fetch.PartPath(htmlPath), wpart) // the staged HTML and both part files never leak
	vars := []string{"SDIR=" + sdir, "DEST=" + dest, "HTML=" + htmlPath, "REPLACE=" + boolDigit(r.replace)}

	effective := ""
	if code := x.track(vars, func(ctx context.Context) int {
		var c int
		effective, c = x.fetch.Fetch(ctx, url, htmlPath, true)
		return c
	}); code != 0 {
		return x.asExit(code)
	}
	if err := os.Rename(x.fetch.PartPath(htmlPath), htmlPath); err != nil {
		x.printf("fetch-doc: could not move download into place: %s\n", htmlPath)
		return exitFailure
	}
	// The snapshot is written to a part file and moved into place, so a pandoc or copy that dies mid-write cannot
	// truncate an already-registered snapshot. The conversion is a tracked stage: a TERM kills pandoc itself.
	if code := x.track(vars, func(ctx context.Context) int { return x.convert(ctx, htmlPath, wpart) }); code != 0 {
		return x.asExit(code)
	}
	// ignored signals are inherited across exec: blocking before pandoc would make it uncancellable
	sha, code := x.stage(wpart)
	if code != 0 {
		return code
	}
	same, code := pl.Install(wpart, dest)
	if code != 0 {
		return code
	}
	_ = os.Remove(htmlPath)
	if same {
		fmt.Fprintf(x.d.Out, "OK: %s -> %s  (identical snapshot already registered; no new row)\n", url, dest)
		return 0
	}
	if code := x.register(sdir, dest, "web-snapshot", effective, sha); code != 0 {
		return code
	}
	fmt.Fprintf(x.d.Out, "OK: %s -> %s  (snapshot markdown, registered)\n", url, dest)
	return 0
}

// convert is pandoc html -> gfm into out, falling back to a plain copy of the HTML when pandoc is absent or fails.
func (x *exe) convert(ctx context.Context, html, out string) int {
	if x.d.have("pandoc") {
		if x.d.Run.Run(ctx, []string{"pandoc", "-f", "html", "-t", "gfm", html, "-o", out}, nil, nil) == 0 {
			return 0
		}
		if ctx.Err() != nil {
			return exitFailure // cancelled: the caller reports the signal
		}
	}
	if err := copyFile(html, out); err != nil {
		x.printf("fetch-doc: cannot copy the page into %s: %v\n", out, err)
		return exitFailure
	}
	return 0
}

// copyFile copies src over dst; dst is created with the process umask applied (0666 &^ umask).
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return err
	}
	return out.Close()
}
