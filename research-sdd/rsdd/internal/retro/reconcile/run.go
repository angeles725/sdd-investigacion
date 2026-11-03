package reconcile

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// ErrUsage marks a call without the one thing every audit needs (a retro or All, a kit root, a working
// directory, an environment reader).
var ErrUsage = errors.New("reconcile: usage")

// Options configure one audit.
type Options struct {
	// Retro is the retro file to audit; ignored under All.
	Retro string
	// All audits every retro of every target registered in the kit's TARGETS.md and ends with a fleet summary.
	All bool
	// IssuesCache holds the pre-fetched open issue bodies (CacheFile, CacheBodies or LoadCache). nil asks for the
	// live per-retro gh query. A cache from LoadCache is re-verified: when it reports untracked rows, the audit
	// runs again against a live per-retro query and that outcome is the result.
	IssuesCache *Cache
	// ClosedCache holds the pre-fetched bodies of the issues closed AS COMPLETED (--closed-cache). With an
	// IssuesCache and no ClosedCache the closed-issue check is skipped and says so on stderr; with neither, the
	// closed issues are queried live.
	ClosedCache *Cache
	// GH is the bounded gh launcher for the live queries; its Env is the caller's environment (PATH included).
	GH gh.Options
	// Repo is the repository whose issues are read; DefaultRepo when empty.
	Repo string
	// Timeout bounds the whole audit; 0 = no bound beyond ctx.
	Timeout time.Duration
	// KitRoot is the kit checkout holding research-sdd/TARGETS.md (the legacy "two directories above toolbelt").
	KitRoot string
	// Cwd resolves a relative Retro. Required: the caller passes its cli.Stdio working directory (archtest
	// forbids os.Getwd outside cli/stdio.go).
	Cwd string
	// Env reads the environment (RESEARCH_HOME, HOME for TARGETS.md paths, RECONCILE_ISSUES_*). Required, for the
	// same reason.
	Env func(string) string
	// Sleep waits before the one retry of the state_reason listing; nil sleeps for real (until ctx ends).
	Sleep func(context.Context, time.Duration)
	// Now is the clock for an X-RateLimit-Reset header; nil reads no clock, so that header falls back to the
	// default backoff (archtest forbids time.Now outside cli/stdio.go).
	Now func() time.Time
}

// Run audits one retro (or every retro under Options.All).
//
// The error is operational only: a context deadline (wrapped, so errors.Is(err, context.DeadlineExceeded)
// holds), ErrUsage, or a gh run that could not be finished. Every legacy-visible outcome, degraded and
// absent-input included, is a Report. The Report is meaningful only when err == nil: every error path returns
// Report{}.
//
// The deadline is the earlier of ctx's and Options.Timeout; it is checked before each gh call and between rows,
// so a gh call already running finishes (bounded by the gh launcher) before the error is returned.
func Run(ctx context.Context, o Options) (Report, error) {
	if o.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, o.Timeout)
		defer cancel()
	}
	rep, err := once(ctx, o)
	if err != nil {
		return Report{}, err
	}
	if !o.All && o.IssuesCache != nil && o.IssuesCache.prefetched && len(rep.Untracked) > 0 {
		o.IssuesCache = nil // the batch listing may be stale or capped: ask gh about this retro itself
		return once(ctx, o)
	}
	return rep, nil
}

func once(ctx context.Context, o Options) (Report, error) {
	if err := ctx.Err(); err != nil {
		return Report{}, fmt.Errorf("reconcile: %w", err)
	}
	switch {
	case o.Retro == "" && !o.All:
		return Report{}, fmt.Errorf("%w: no retro given", ErrUsage)
	case o.KitRoot == "":
		return Report{}, fmt.Errorf("%w: no kit root given", ErrUsage)
	case o.Cwd == "":
		return Report{}, fmt.Errorf("%w: no working directory given", ErrUsage)
	case o.Env == nil:
		return Report{}, fmt.Errorf("%w: no environment reader given", ErrUsage)
	}
	rep := &Report{}
	limitText, limit, bad := listLimit(o.Env)
	if bad != "" {
		rep.degrade("%s", bad)
		return *rep, nil
	}
	g := newGHClient(ctx, o, limitText, limit)
	sess := newSession(o.KitRoot, o.Env)
	if o.All {
		runAll(ctx, g, sess, rep, o)
	} else {
		resolveAndAudit(ctx, g, sess, rep, o)
	}
	if g.err != nil {
		return Report{}, g.err
	}
	if err := ctx.Err(); err != nil {
		return Report{}, fmt.Errorf("reconcile: %w", err)
	}
	return *rep, nil
}

// resolveAndAudit is the single-retro branch of the legacy main dispatch: validate the path (absent-input),
// derive the target NAME exactly as stage-retro-issues.sh does (kit issue #1287), then audit.
func resolveAndAudit(ctx context.Context, g *ghClient, sess *session, rep *Report, o Options) {
	cwd, env := o.Cwd, o.Env
	retro := o.Retro
	if abs := absPath(cwd, retro); !isRegular(abs) {
		rep.fail("absent-input: retro not found: %s", retro)
		return
	}
	dir := filepath.Dir(retro)
	retro = filepath.Join(absPath(cwd, dir), filepath.Base(retro))
	targetDir := filepath.Dir(filepath.Dir(retro))
	targetsMD := filepath.Join(o.KitRoot, "research-sdd", "TARGETS.md")
	res, err := kit.NameForRetro(targetsMD, retro, cwd, env)
	for _, w := range res.Warnings {
		rep.note("%s", w)
	}
	name := res.Name
	switch {
	case err == nil && name != "":
	case err != nil && kit.RC(err) == 1:
		rep.note("%s", err.Error())
		rep.fail("reconcile-issues: cannot resolve target for '%s' — operational failure reading %s (see message above)", retro, targetsMD)
		return
	default:
		// No registered ancestor: a flat layout keeps the WARN + basename fallback; a structural directory is
		// refused (the writer refuses it too, so no issue can exist).
		name = filepath.Base(targetDir)
		if name == "corpus" || name == "retros" {
			rep.fail("reconcile-issues: cannot resolve target for '%s' — no ancestor directory is registered in %s (basename '%s' is a structural directory, not a target)", retro, targetsMD, name)
			return
		}
		rep.note("WARN: target directory '%s' not found in %s — using basename '%s'", targetDir, targetsMD, name)
	}
	(&audit{ctx: ctx, sess: sess, gh: g, closed: o.ClosedCache, rep: rep, path: retro, base: filepath.Base(retro), target: name, cache: o.IssuesCache}).run()
	sess.shallowNote(rep)
}

func absPath(cwd, p string) string {
	if !filepath.IsAbs(p) {
		p = filepath.Join(cwd, p)
	}
	return filepath.Clean(p)
}

func isRegular(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}
