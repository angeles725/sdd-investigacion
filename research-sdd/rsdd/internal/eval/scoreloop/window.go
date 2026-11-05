package scoreloop

import (
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	gitrun "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

const gitLogTimeout = 5 * time.Minute

// logFormat is `<sha> TAB <committer date, strict ISO> TAB <subject>`.
const logFormat = "--format=%H%x09%cI%x09%s"

// window reads block commits from the corpus's git history.
type window struct {
	cfg    *Config
	git    gitrun.Runner
	corpus string
	// baseRef scopes every scan to <baseRef>..HEAD (HEAD alone when empty).
	baseRef string
	errw    io.Writer
}

// scanResult is what one `git log` returned: the weighted block commits, in time order, and the proof that the
// instrument looked (every candidate commit examined, and the commits whose date did not parse).
type scanResult struct {
	entries  []blockEntry
	examined int
	tsErrors int
}

// scanError is a `git log` that failed; the message is the legacy operational-failure line.
type scanError struct{ msg string }

func (e *scanError) Error() string { return e.msg }

// scan lists the block commits in [since, until] (either may be empty: unbounded). A failing `git log`, such as a
// bad --base-ref, is returned, never swallowed.
func (w *window) scan(since, until string) (scanResult, error) {
	rng := "HEAD"
	if w.baseRef != "" {
		rng = w.baseRef + "..HEAD"
	}
	args := []string{"log", "--no-color", logFormat}
	if since != "" {
		args = append(args, "--since="+since)
	}
	if until != "" {
		args = append(args, "--until="+until)
	}
	out, err := w.git.Run(w.corpus, append(args, rng, "--", ".")...)
	if err != nil {
		return scanResult{}, &scanError{fmt.Sprintf("%s: git log failed (%s) for window '%s': %s", scriptName, gitFailure(err), rng, gitStderr(err))}
	}
	return w.parseLog(string(out)), nil
}

func (w *window) parseLog(out string) scanResult {
	var res scanResult
	for _, line := range strings.Split(out, "\n") {
		fields := strings.SplitN(line, "\t", 3)
		if fields[0] == "" {
			continue
		}
		res.examined++
		if len(fields) < 3 {
			continue
		}
		b := w.cfg.weigh(fields[2])
		if !b.matched {
			continue
		}
		if b.implausible {
			fmt.Fprintf(w.errw, "%s: WARN: implausible block range B%s-B%s in commit %s (span >%s) — counting as 1 block\n",
				scriptName, b.start, b.end, fields[0], w.cfg.RangeCap)
		}
		when, ok := parseTimestamp(fields[1])
		if !ok {
			res.tsErrors++
			continue
		}
		res.entries = append(res.entries, blockEntry{epoch: when.Unix(), weight: b.weight})
	}
	sort.SliceStable(res.entries, func(i, j int) bool { return res.entries[i].epoch < res.entries[j].epoch })
	return res
}

func gitFailure(err error) string {
	var ee *gitrun.ExitError
	if errors.As(err, &ee) {
		return fmt.Sprintf("exit %d", ee.Code)
	}
	return err.Error()
}

// gitStderr is git's own stderr with newlines flattened to spaces (the legacy `tr '\n' ' '`).
func gitStderr(err error) string {
	var ee *gitrun.ExitError
	if errors.As(err, &ee) {
		return strings.ReplaceAll(ee.Stderr, "\n", " ")
	}
	return ""
}
