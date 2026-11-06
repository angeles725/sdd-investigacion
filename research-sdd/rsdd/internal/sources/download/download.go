// Package download fetches one URL into a sibling PART file and returns the URL to register.
//
// Evidence does not die: a download never lands straight in the destination, because a failed or partial transfer
// (curl dying mid-body, wget truncating, an empty 200) would destroy an already-registered file whose SOURCES.md
// row then points at evidence that is gone. The bytes go to "<final>.fetchdoc-part.<pid>" (PartSuffix) and only a
// non-empty, confirmed transfer is kept; with KeepPart the caller moves it into place, so a run cancelled between
// the two never replaces anything.
package download

import (
	"context"
	"fmt"
	"io"
	"os"
	"strconv"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/redirect"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner"
)

// PartMarker is the unambiguous marker of a part file's name (a registered document may legitimately be called
// "spec.part.123"); the suffix is PartMarker + pid.
const PartMarker = ".fetchdoc-part."

// Cancelled is the code of a run stopped by its context: the caller reports the signal's exit status.
const Cancelled = -1

// Fetcher downloads through curl (with permanent-redirect resolution), falling back to wget.
type Fetcher struct {
	Run runner.Runner
	// Have reports whether a tool is on the PATH.
	Have func(name string) bool
	Err  io.Writer
	// Pid names the part file.
	Pid int
}

// PartPath is the part file of final for this fetcher's pid.
func (f Fetcher) PartPath(final string) string { return final + PartMarker + strconv.Itoa(f.Pid) }

// Fetch resolves the permanent-redirect destination of url (curl only), downloads it with `curl -fsS -L` (-L is
// load-bearing: the resolved URL may still sit behind a temporary hop, and without it curl saves the REDIRECT
// response as the document) and returns the URL to register. On a curl failure it retries with wget against the
// TYPED url (wget cannot confirm redirects) and registers that, announced on stderr. Failures print their own
// message and return a non-zero exit code; Cancelled means the context stopped the run. With keepPart the part
// file is left for the caller to move; without it Fetch moves it over final.
func (f Fetcher) Fetch(ctx context.Context, url, final string, keepPart bool) (string, int) {
	part := f.PartPath(final)
	if f.Have("curl") {
		effective := redirect.Resolver{Run: f.Run, Err: f.Err}.Resolve(ctx, url)
		if ctx.Err() != nil {
			return "", Cancelled
		}
		rc := f.Run.Run(ctx, []string{"curl", "-fsS", "-L", effective, "-o", part}, nil, f.Err)
		if ctx.Err() != nil {
			return "", Cancelled
		}
		if rc == 0 {
			return f.finish(url, effective, part, final, keepPart)
		}
	}
	_ = os.Remove(part) // a curl failure may have left a partial part file; wget starts from scratch
	return f.wget(ctx, url, part, final, keepPart)
}

// finish confirms a curl download: a 200 can still carry an EMPTY body, which must never replace a registered file
// nor print a success notice.
func (f Fetcher) finish(url, effective, part, final string, keepPart bool) (string, int) {
	if !nonEmpty(part) {
		_ = os.Remove(part)
		fmt.Fprintf(f.Err, "fetch-doc: empty body: %s\n", url)
		return "", 1
	}
	if code := f.move(part, final, keepPart); code != 0 {
		return "", code
	}
	if effective != url {
		fmt.Fprintf(f.Err, "fetch-doc: registered %s (permanent redirect from %s)\n", effective, url)
	}
	return effective, 0
}

func (f Fetcher) wget(ctx context.Context, url, part, final string, keepPart bool) (string, int) {
	wgetRC := -1 // -1: wget was not run (not installed)
	if f.Have("wget") {
		wgetRC = f.Run.Run(ctx, []string{"wget", "-q", url, "-O", part}, nil, f.Err)
		if ctx.Err() != nil {
			_ = os.Remove(part)
			return "", Cancelled
		}
	}
	if wgetRC == 0 && nonEmpty(part) {
		if code := f.move(part, final, keepPart); code != 0 {
			return "", code
		}
		fmt.Fprintln(f.Err, "fetch-doc: registered requested URL (wget fallback; effective URL unknown)")
		return url, 0
	}
	// Real `wget -O` creates or truncates its target even when the request fails: remove the part file so no
	// debris is left in the target's evidence tree.
	_ = os.Remove(part)
	switch wgetRC {
	case -1:
		fmt.Fprintf(f.Err, "fetch-doc: curl failed and wget is not installed for %s; nothing registered\n", url)
	case 0:
		fmt.Fprintf(f.Err, "fetch-doc: empty body: %s (wget fallback); nothing registered\n", url)
	default:
		fmt.Fprintf(f.Err, "fetch-doc: wget fallback ALSO failed for %s; nothing registered\n", url)
	}
	return "", 1
}

func (f Fetcher) move(part, final string, keepPart bool) int {
	if keepPart {
		return 0
	}
	if err := os.Rename(part, final); err != nil {
		_ = os.Remove(part)
		fmt.Fprintf(f.Err, "fetch-doc: could not move download into place: %s\n", final)
		return 1
	}
	return 0
}

// nonEmpty is `[ -s path ]`: the file exists and has bytes.
func nonEmpty(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Size() > 0
}
