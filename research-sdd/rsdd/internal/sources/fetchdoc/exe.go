package fetchdoc

import (
	"context"
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/download"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/place"
)

// exe is one run of the command: its dependencies, its signal session and the seam.
type exe struct {
	d     Deps
	sess  *session
	seam  *seam
	fetch download.Fetcher
}

// Execute runs `fetch-doc [--replace] doc|web|ocr ...` and returns the exit status (1 failure, 2 usage, 3 missing
// dependency, 4 destination exists, 5 symlinked destination, 130/143 cancelled by INT/TERM).
func Execute(args []string, d Deps) int {
	x := &exe{d: d, sess: newSession(d.Signals), seam: newSeam(d)}
	defer x.sess.Close()
	x.fetch = download.Fetcher{Run: d.Run, Have: d.have, Err: d.Err, Pid: d.Pid}
	r := parse(args)
	switch r.mode {
	case "":
		return x.usageError(usageGeneral, "missing mode")
	case "doc":
		return x.doc(r)
	case "web":
		return x.web(r)
	case "ocr":
		return x.ocr(r)
	}
	return x.modeError(r.mode)
}

// modeError is an unknown MODE: the legacy message and exit 2.
func (x *exe) modeError(mode string) int {
	x.printf("unknown mode: %s (doc|web|ocr)\n", mode)
	return exitUsage
}

// placer is the overwrite-policy helper of one sources directory.
func (x *exe) placer(sdir string, replace bool, vars ...string) *place.Placer {
	return &place.Placer{SDir: sdir, Replace: replace, Err: x.d.Err, Hook: func(pt string) {
		x.seam.fire(pt, append([]string{"SDIR=" + sdir, "REPLACE=" + boolDigit(replace)}, vars...))
	}}
}

// track runs one cancellable stage: the seam's "after-fork" point, then fn under the session's context. An INT/TERM
// received before, during or right after fn wins over fn's own status: the run exits 130/143 and registers nothing.
func (x *exe) track(vars []string, fn func(ctx context.Context) int) int {
	x.seam.fire("after-fork", vars)
	if c, ok := x.sess.interrupted(); ok {
		return c
	}
	code := fn(x.sess.ctx)
	if c, ok := x.sess.interrupted(); ok {
		return c
	}
	return code
}

// needDownloader is the runtime-dependency probe: with NEITHER curl nor wget the run can only fail, and "wget
// fallback ALSO failed" would hide the real cause.
func (x *exe) needDownloader() int {
	if !x.d.have("curl") && !x.d.have("wget") {
		x.printf("fetch-doc: DEGRADED: neither curl nor wget is installed — cannot download; nothing registered\n")
		return exitMissing
	}
	return 0
}

func (x *exe) alive() func(string) bool { return x.d.Alive }

func (x *exe) printf(format string, a ...any) { fmt.Fprintf(x.d.Err, format, a...) }

func boolDigit(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// removeAll deletes files best-effort (cleanup that must not mask the run's own status).
func removeAll(paths ...string) {
	for _, p := range paths {
		_ = os.Remove(p)
	}
}
