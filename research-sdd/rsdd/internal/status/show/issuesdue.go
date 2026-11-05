package show

import (
	"fmt"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The ISSUES-DUE gate, the --next terminal (issues_due_gate). When the NEXT walk is exhausted, every retro under the
// target is probed for deltas no GitHub issue tracks (`retro reconcile`, one probe per retro); the first retro with
// untracked deltas turns the exhausted STOP into ISSUES-DUE, so the caller seeds them as issues.
//
// Anti-silent-zero (§7): "could not look" is never "found nothing". A retro enumeration that failed, a probe that
// timed out, degraded or failed, an out-of-scope review marker, a batch the aggregate budget cut short: each is named
// on stderr and makes the verdict STOP with the generic suffix `[issue-coverage: unverified]`. Untracked wins over
// unverified, unverified over verified-clean. A retro whose marker is applied or dismissed costs no probe.

const (
	idgRepo           = "angeles725/sdd-investigacion"
	idgDefaultTimeout = 15 // _IDG_RECONCILE_TIMEOUT_SECS: the bound of one gh call or probe, in seconds
	idgDefaultBudget  = 60 // _IDG_AGGREGATE_BUDGET_SECS: the wall budget of verifying every retro clean
	idgDefaultLimit   = "5000"
)

// issuesDueGate prints the terminal verdict of an exhausted walk: ISSUES-DUE, the unverified STOP or the clean STOP.
func (c *ctx) issuesDueGate() {
	g := &issuesGate{c: c}
	retros, rc := c.retroFiles()
	if rc != 0 { // IDG-FIND-EXIT-UNVERIFIED: the visible retros are still probed
		g.unverified = true
		c.warnf("WARN: retro enumeration incomplete (find exit %d) — treating coverage as unverified\n", rc)
	}
	if len(retros) > 0 && g.probe(retros) {
		return // ISSUES-DUE printed
	}
	if g.unverified {
		fmt.Fprintf(c.s.Out, "%s [issue-coverage: unverified]%s\n", stopExhausted, c.buSuffix) // IDG-UNVERIFIED-MARKER
	} else {
		fmt.Fprintf(c.s.Out, "%s%s\n", stopExhausted, c.buSuffix)
	}
	c.terminalCleanWarn()
}

func (c *ctx) warnf(format string, a ...any) { fmt.Fprintf(c.s.Err, format, a...) }

type issuesGate struct {
	c          *ctx
	unverified bool
	secs       time.Duration // the bound of one call
}

// knob is `${NAME:-dflt}` for a non-negative integer; anything else is the default.
func (c *ctx) knob(name string, dflt int) int {
	if n, ok := intOf(c.s.Env(name)); ok && n <= 1<<31 {
		return int(n)
	}
	return dflt
}

// probe walks the retros; it answers true when it printed ISSUES-DUE.
func (g *issuesGate) probe(retros []string) bool {
	c := g.c
	o := c.ghOptions()
	g.secs = time.Duration(gh.ResolveBound(o.Env, o.Knob, o.Default).Seconds) * time.Second
	budget := time.Duration(c.knob("_IDG_AGGREGATE_BUDGET_SECS", idgDefaultBudget)) * time.Second
	start := c.now()
	cache := g.prefetch()
	if cache != "" {
		defer os.Remove(cache)
	}
	for _, retro := range retros {
		if retroSettled(c.abs(retro)) {
			continue // PERF: an applied or dismissed retro needs no probe
		}
		if c.now().Sub(start) >= budget { // IDG-AGGREGATE-EXCEEDED
			g.unverified = true
			c.warnf("WARN: aggregate reconcile budget (%ss) exceeded — marking coverage unverified\n", strconv.Itoa(int(budget/time.Second)))
			break
		}
		if n, ok := g.untracked(retro, cache); ok && n > 0 {
			fmt.Fprintf(c.s.Out, "ISSUES-DUE | %d untracked delta(s) in %s — seed: stage-retro-issues.sh %s --apply\n", n, retro, retro) // IDG-EARLY-EXIT
			return true
		}
	}
	return false
}

// now is the clock of the run; without one, no time passes.
func (c *ctx) now() time.Time {
	if c.s.Clock == nil {
		return time.Time{}
	}
	return c.s.Clock()
}

// retroSettled is `retro_review_status` in applied|dismissed: the leading-block marker of the retro.
func retroSettled(file string) bool {
	src, err := os.ReadFile(file)
	if err != nil {
		return false
	}
	switch retrogrammar.ReviewStatus(retrogrammar.Parse(file, string(src))) {
	case "applied", "dismissed":
		return true
	}
	return false
}

// prefetch is the batch fetch: ONE `gh issue list` of every open issue body, bounded, written to a temp file the
// probes read (`--issues-cache`). Any failure leaves the cache empty and every probe does its own gh query. The
// path is "" when there is no cache.
func (g *issuesGate) prefetch() string {
	c := g.c
	f, err := os.CreateTemp(c.s.Env("TMPDIR"), "tmp.") // mktemp
	if err != nil {
		g.unverified = true
		c.warnf("WARN: mktemp failed for issue-cache — marking coverage unverified\n")
		return ""
	}
	res, err := ghList(c.ghOptions(), "issue", "list", "--repo", idgRepo, "--state", "open", "--json", "body",
		"--limit", orDefault(c.s.Env("_IDG_BATCH_LIMIT"), idgDefaultLimit), "--jq", ".[].body")
	if err != nil || res.State != "OK" { // IDG-BATCH-FAILURE: incl. the bound (124): per-retro fallback
		_ = f.Close()
		_ = os.Remove(f.Name())
		c.warnf("WARN: batch issue prefetch failed (exit %d) — falling back to per-retro reconcile\n", shellExit(res, err))
		return ""
	}
	_, werr := f.WriteString(strings.TrimRight(string(res.Stdout), "\n") + "\n")
	if cerr := f.Close(); werr != nil || cerr != nil {
		_ = os.Remove(f.Name())
		g.unverified = true
		c.warnf("WARN: mktemp failed for issue-cache — marking coverage unverified\n")
		return ""
	}
	return f.Name()
}

// reconcile is one bounded probe of a retro, with or without the batch cache.
func (g *issuesGate) reconcile(retro, cache string) probeResult {
	args := []string{retro}
	if cache != "" {
		args = []string{"--issues-cache", cache, retro}
	}
	return reconcileRun(args, g.secs, g.c.s)
}

// failed classifies a probe that did not exit 0 as unverified coverage and says why on stderr, in the words of the
// failing step: the bound fired (124), gh degraded (a `degraded:` line on stderr), or any other failure.
func (g *issuesGate) failed(r probeResult, retro, timedOut, degraded, failure string) {
	g.unverified = true
	name := path.Base(retro)
	errText := strings.TrimRight(r.err, "\n")
	switch {
	case r.rc == 124:
		g.c.warnf(timedOut, name)
	case hasLinePrefix(errText, "degraded:"):
		g.c.warnf("%s", degraded)
	default:
		if errText == "" {
			errText = "no stderr"
		}
		g.c.warnf(failure, name, r.rc, errText)
	}
}

// untracked probes one retro and answers its count of untracked deltas; ok is false when the retro is unverified
// (the reason is on stderr) and must not count.
func (g *issuesGate) untracked(retro, cache string) (n int, ok bool) {
	c := g.c
	r := g.reconcile(retro, cache)
	if r.rc != 0 {
		g.failed(r, retro, "WARN: reconcile-issues.sh timed out for %s — treating as unverified\n",
			"WARN: could not verify issue coverage (gh degraded) — seed manually\n",
			"WARN: reconcile-issues.sh failed for %s (exit %d) — %s\n")
		return 0, false
	}
	// A retro's own marker out of scope exits 0 (a corpus finding), but its rows were never classified: not clean.
	if hasLinePrefix(strings.TrimRight(r.err, "\n"), "out-of-scope-marker:") { // IDG-OOS-SENTINEL
		g.unverified = true
		c.warnf("WARN: reconcile-issues.sh reported an out-of-scope review-status marker for %s — treating as unverified\n", path.Base(retro))
		return 0, false
	}
	n = countUntracked(r.out)
	if n == 0 || cache == "" {
		return n, true
	}
	// IDG-BATCH-UNTRACKED-REVERIFY: positive evidence (tracked) from the batch is trustworthy, negative evidence is
	// not (a truncated, empty or rate-limited batch, or a page at the --limit cap): one narrowed per-retro query.
	rv := g.reconcile(retro, "")
	if rv.rc != 0 {
		g.failed(rv, retro, "WARN: re-verify timed out for %s — treating as unverified\n",
			"WARN: could not re-verify issue coverage (gh degraded) — seed manually\n",
			"WARN: re-verify failed for %s (exit %d) — %s\n")
		return 0, false
	}
	return countUntracked(rv.out), true // the re-verified count: tracked there means the batch was a false negative
}

// countUntracked is `awk '/^untracked:/{n++} END{print n+0}'`.
func countUntracked(out string) int {
	n := 0
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "untracked:") {
			n++
		}
	}
	return n
}

// hasLinePrefix is `grep -qE '^<prefix>'` over text.
func hasLinePrefix(text, prefix string) bool {
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}
