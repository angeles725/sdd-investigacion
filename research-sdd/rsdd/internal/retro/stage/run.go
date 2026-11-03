package stage

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Exit codes. 0 staged; 1 usage, a retro that cannot be read, or an option the command does not know; 2 the retro
// is excluded or already applied|dismissed; 3 the kit repo has uncommitted changes; 4 git cannot report the state
// of the kit repo (the script's "cannot checkout main" code: the port no longer switches to main, so this is the
// one place that code is left); 5 the retro branch cannot be created or checked out; 6 `git fetch origin` failed;
// 7 the retro is in the kit repo itself but origin/main does not hold the same content; 8 the retro is unreadable
// on the branch after the checkout.
const (
	exitUsage      = 1
	exitRefused    = 2
	exitDirty      = 3
	exitGitState   = 4
	exitBranch     = 5
	exitFetch      = 6
	exitSelfRef    = 7
	exitStaleRetro = 8
)

// DefaultFetchTimeout bounds one `git fetch origin`; the script never bounded it.
const DefaultFetchTimeout = 120 * time.Second

// Options configure one run.
type Options struct {
	// Args are the command-line arguments after the command name: the retro, then any number of --force.
	Args []string
	// KitRoot is the physical kit repo root (two directories above the toolbelt).
	KitRoot string
	// Cwd resolves a relative retro.
	Cwd string
	// Getenv reads one variable of the caller's environment (RESEARCH_HOME and HOME expand the target registry).
	Getenv func(string) string
	// Environ is the whole environment handed to git; nil leaves it to the process.
	Environ []string
	// Out and Err are stdout and stderr.
	Out, Err io.Writer
	// Read loads a retro; nil means retrogrammar.Read. It is called before any git call (the status gate) and once
	// more after the branch is checked out (the file printed is the one on the branch). A test makes it fail to
	// reach the unreadable branches without chmod, which root ignores.
	Read func(path string) (*retrogrammar.Doc, error)
	// FetchTimeout bounds `git fetch origin`; 0 means DefaultFetchTimeout.
	FetchTimeout time.Duration
}

// stager is one run.
type stager struct {
	o      Options
	git    git.Runner
	out    io.Writer
	err    io.Writer
	retro  string // the retro as the caller wrote it (the messages quote it)
	path   string // the retro resolved against Cwd
	force  bool
	label  string // the target name, the registered one when the registry gives it
	slug   string
	branch string
	orig   head // where the kit checkout stood before the branch was created
}

// Run stages one retro and returns the exit code.
func Run(o Options) int {
	s := &stager{o: o, git: git.Runner{Env: o.Environ}, out: o.Out, err: o.Err}
	return s.run()
}

func (s *stager) outf(format string, a ...any) { fmt.Fprintf(s.out, format, a...) }
func (s *stager) errf(format string, a ...any) { fmt.Fprintf(s.err, format, a...) }

func (s *stager) run() int {
	if rc, done := s.parseArgs(); done {
		return rc
	}
	doc, rc, done := s.load()
	if done {
		return rc
	}
	if rc, done := s.gate(doc); done {
		return rc
	}
	s.label = s.targetLabel()
	s.slug = slugOf(s.retro)
	s.branch = "retro/" + s.label + "-" + s.slug
	retroRef := s.label + "/retros/" + filepath.Base(s.retro)
	if sha := s.trackedSHA(); sha != "" {
		retroRef += "@" + sha
	}
	if rc, done := s.preflight(); done {
		return rc
	}
	s.outf(">> staging retro for supervised review\n   retro : %s\n   target: %s\n   branch: %s\n\n", s.retro, s.label, s.branch)
	if out, err := s.fetch(); err != nil {
		s.errf("%s", out)
		s.errf("degraded: git fetch origin failed — cannot verify remote state; refusing to branch from a possibly stale base.\n")
		return exitFetch
	}
	if rc, done := s.guardSelfReference(); done {
		return rc
	}
	orig := s.currentHead()
	if rc, done := s.checkout(orig); done {
		return rc
	}
	return s.report(retroRef)
}

// parseArgs is the script's `retro="${1:-}"` guard plus the one option it had (--force, honoured only as $2).
// The script ignored every other word after the retro, so a mistyped `--forse` staged as if nothing had been
// said; any word that is not --force is now refused before anything is read or changed.
func (s *stager) parseArgs() (int, bool) {
	args := s.o.Args
	if len(args) == 0 || args[0] == "" {
		return s.usage()
	}
	s.retro = args[0]
	s.path = s.resolve(s.retro)
	if st, err := os.Stat(s.path); err != nil || !st.Mode().IsRegular() {
		return s.usage()
	}
	for _, a := range args[1:] {
		if a != "--force" {
			s.errf("stage-retro: unknown argument '%s' (the only option after the retro is --force)\n", a)
			return exitUsage, true
		}
		s.force = true
	}
	return 0, false
}

func (s *stager) usage() (int, bool) {
	s.errf("usage: stage-retro.sh <path-to-retro.md>\n")
	return exitUsage, true
}

// resolve places a relative path under the caller's working directory.
func (s *stager) resolve(p string) string {
	if filepath.IsAbs(p) || s.o.Cwd == "" {
		return p
	}
	return s.o.Cwd + "/" + p // concatenated, never Clean'd: "link/../x" must resolve as the kernel does
}

func (s *stager) read(path string) (*retrogrammar.Doc, error) {
	if s.o.Read != nil {
		return s.o.Read(path)
	}
	return retrogrammar.Read(path)
}

// load reads the retro once, before any git call. The script never checked that it could read the file: an
// unreadable retro read as "no marker", so a branch was created for it and the run failed only after the
// checkout (exit 8). It is refused here, before anything is touched.
func (s *stager) load() (*retrogrammar.Doc, int, bool) {
	doc, err := s.read(s.path)
	switch {
	case errors.Is(err, retrogrammar.ErrAbsentInput):
		rc, done := s.usage()
		return nil, rc, done
	case err != nil:
		s.errf("degraded: retro not readable: %s\n", s.retro)
		return nil, exitUsage, true
	}
	return doc, 0, false
}

// gate is the scope guard and the review-status guard: both refuse before any git mutation.
func (s *stager) gate(doc *retrogrammar.Doc) (int, bool) {
	if retrogrammar.IsExcluded(doc) {
		s.errf("stage-retro: this file carries '<!-- kit-retro: exclude -->' and is not a §18 kit retro — nothing to stage.\n")
		return exitRefused, true
	}
	switch status := retrogrammar.ReviewStatus(doc); status {
	case "applied", "dismissed":
		if !s.force {
			s.errf("This retro is already '%s' — nothing to stage. (Use --force to re-stage.)\n", status)
			return exitRefused, true
		}
		s.errf("This retro is already '%s' — re-staging because --force was given.\n", status)
	}
	return 0, false
}

// report prints the deltas of the retro as it is on the branch, then the next steps.
func (s *stager) report(retroRef string) int {
	// The file printed is the one the checkout left on disk, so it is read again; a branch that predates the
	// retro leaves nothing to print.
	doc, err := s.read(s.path)
	if err != nil {
		return s.retroGone()
	}
	s.outf(">> on branch %s (from origin/main). Proposed deltas to review/apply:\n\n", s.branch)
	deltas, found := section(doc.Raw, reDeltas)
	if !found {
		s.errf("WARN: no '## Proposed kit deltas' section found in %s — there are no deltas to print.\n", s.retro)
	}
	tools, _ := section(doc.Raw, reTools)
	s.outf("%s\n%s\n", joinLines(deltas), joinLines(tools))
	s.nextSteps(retroRef)
	return 0
}
