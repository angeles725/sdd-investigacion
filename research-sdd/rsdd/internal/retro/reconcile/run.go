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

// ErrNotInSlice marks a request the port does not serve yet (live gh, --all, the closed-issue classes); the
// legacy script still does. It is an operational error, never a verdict.
var ErrNotInSlice = errors.New("reconcile: not in this slice of the port")

// ErrUsage marks a call without the one thing every audit needs (a retro, a kit root).
var ErrUsage = errors.New("reconcile: usage")

// Options configure one audit.
type Options struct {
	// Retro is the retro file to audit.
	Retro string
	// IssuesCache holds the pre-fetched open issue bodies. nil asks for a per-retro gh query, which is not in
	// this slice (ErrNotInSlice).
	IssuesCache *Cache
	// GH is the bounded gh launcher for the per-retro query (unused until live gh lands).
	GH gh.Options
	// Timeout bounds the whole audit; 0 = no bound beyond ctx.
	Timeout time.Duration
	// KitRoot is the kit checkout holding research-sdd/TARGETS.md (the legacy "two directories above toolbelt").
	KitRoot string
	// Cwd resolves a relative Retro; "" = the process working directory.
	Cwd string
	// Env reads the environment (RESEARCH_HOME, HOME for TARGETS.md paths); nil = os.Getenv.
	Env func(string) string
}

// Run audits one retro. The error is operational only: a context deadline (wrapped, so errors.Is(err,
// context.DeadlineExceeded) holds), ErrUsage or ErrNotInSlice. Every legacy-visible outcome, degraded and
// absent-input included, is a Report.
func Run(ctx context.Context, o Options) (Report, error) {
	if o.Timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, o.Timeout)
		defer cancel()
	}
	if err := ctx.Err(); err != nil {
		return Report{}, fmt.Errorf("reconcile: %w", err)
	}
	switch {
	case o.Retro == "":
		return Report{}, fmt.Errorf("%w: no retro given", ErrUsage)
	case o.KitRoot == "":
		return Report{}, fmt.Errorf("%w: no kit root given", ErrUsage)
	case o.IssuesCache == nil:
		return Report{}, fmt.Errorf("%w: a per-retro gh query (nil IssuesCache)", ErrNotInSlice)
	}
	cwd, env := o.Cwd, o.Env
	if cwd == "" {
		wd, err := os.Getwd()
		if err != nil {
			return Report{}, fmt.Errorf("reconcile: working directory: %w", err)
		}
		cwd = wd
	}
	if env == nil {
		env = os.Getenv
	}
	rep := &Report{}
	if err := resolveAndAudit(rep, o, cwd, env); err != nil {
		return Report{}, err
	}
	if err := ctx.Err(); err != nil {
		return Report{}, fmt.Errorf("reconcile: %w", err)
	}
	return *rep, nil
}

// resolveAndAudit is the single-retro branch of the legacy main dispatch: validate the path (absent-input),
// derive the target NAME exactly as stage-retro-issues.sh does (kit issue #1287), then audit.
func resolveAndAudit(rep *Report, o Options, cwd string, env func(string) string) error {
	retro := o.Retro
	if abs := absPath(cwd, retro); !isRegular(abs) {
		rep.fail("absent-input: retro not found: %s", retro)
		return nil
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
		return nil
	default:
		// No registered ancestor: a flat layout keeps the WARN + basename fallback; a structural directory is
		// refused (the writer refuses it too, so no issue can exist).
		name = filepath.Base(targetDir)
		if name == "corpus" || name == "retros" {
			rep.fail("reconcile-issues: cannot resolve target for '%s' — no ancestor directory is registered in %s (basename '%s' is a structural directory, not a target)", retro, targetsMD, name)
			return nil
		}
		rep.note("WARN: target directory '%s' not found in %s — using basename '%s'", targetDir, targetsMD, name)
	}
	(&audit{rep: rep, path: retro, base: filepath.Base(retro), target: name, cache: o.IssuesCache}).run()
	return nil
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
