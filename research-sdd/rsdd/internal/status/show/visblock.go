package show

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Port of remote_visibility_block (kit #1245): read back the visibility of each git remote. ensure-remote.sh
// verifies PRIVATE only at creation, so a remote made PUBLIC later is invisible without this. The block surfaces
// the state and NEVER flips it (visibility is the owner's decision).
//
//	PUBLIC             -> `WARN public-remote: <remote> ...` on stdout
//	PRIVATE / INTERNAL -> silent; no .git or no remote -> silent
//	anything else      -> a typed `degraded: remote-visibility: ...` line (§7: never a silent pass)
//
// Only the remote NAME is printed and only OWNER/REPO reaches gh's argv: a remote URL may embed credentials. The
// lib/gh-visibility.sh availability line of the script has no counterpart: the probe is core/gh here.

// ghSlug is the github.com owner/repo of a remote URL (scheme and userinfo optional, `:` or `/` after the host).
var ghSlug = regexp.MustCompile(`^(?:[A-Za-z][A-Za-z0-9+.-]*://)?(?:[^/]*@)?github\.com[:/]+([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9_.-]+)/?$`)

// visibilityDefaultSecs is the bound of one probe here (the shared lib defaults to 20, the status script to 10).
const visibilityDefaultSecs = 10

// remoteVisibility prints the block and reports whether it printed a typed degraded line.
func (c *ctx) remoteVisibility() (degraded bool) {
	dir := c.abs(c.target)
	if _, err := os.Stat(dir + "/.git"); err != nil {
		return false
	}
	environ := c.s.Environment()
	remotes, err := git.Runner{Env: environ, Now: c.s.Clock}.Remotes(dir)
	if errors.Is(err, git.ErrMissing) {
		fmt.Fprintf(c.s.Out, "degraded: remote-visibility: git not found — cannot read the remotes of %s\n", c.target)
		return true
	}
	bin := c.s.Env("RSDD_GH_BIN")
	if bin == "" {
		bin = "gh"
	}
	stalled := false
	say := func(format string, a ...any) {
		degraded = true
		fmt.Fprintf(c.s.Out, "degraded: remote-visibility: "+format+"\n", a...)
	}
	for _, r := range remotes {
		if r == "" {
			continue
		}
		if !ghFound(bin, environ, c.s.Cwd) {
			say("gh not found — cannot verify the visibility of remote %s", r)
			continue
		}
		url, uerr := git.Runner{Env: environ, Now: c.s.Clock}.RemoteURL(dir, r)
		if uerr != nil || url == "" {
			say("%s url empty or unreadable — visibility unverified", r)
			continue
		}
		m := ghSlug.FindStringSubmatch(url)
		if m == nil {
			say("%s not a github owner/repo — visibility unverified", r)
			continue
		}
		if stalled { // N stalled remotes cost one bound, not N
			say("skipped after timeout for remote %s — visibility unverified", r)
			continue
		}
		v, _ := ghProbe(gh.Options{Bin: bin, Env: environ, Dir: c.s.Cwd, Default: visibilityDefaultSecs, Now: c.s.Clock}, m[1]+"/"+strings.TrimSuffix(m[2], ".git"))
		switch v.State {
		case gh.StateTimeout:
			stalled = true
			say("gh timed out for remote %s — visibility unverified", r)
		case gh.StateError:
			say("gh failed (rc=%d) for remote %s — visibility unverified", v.RC, r)
		case gh.StateMissing, gh.StateProbeFailed:
			say("gh probe could not run (%s) for remote %s — visibility unverified", v.State, r)
		default:
			c.visibilityAnswer(r, v.Raw, say)
		}
	}
	return degraded
}

// visibilityAnswer reports one decided-or-not gh answer.
func (c *ctx) visibilityAnswer(remote, raw string, say func(string, ...any)) {
	switch raw {
	case "PUBLIC":
		fmt.Fprintf(c.s.Out, "WARN public-remote: %s is PUBLIC — METHODOLOGY §15: a corpus remote is NEVER public; audit tracked files (ls-files) for decompiled/proprietary paths before any push. Visibility is the owner's call; this check never changes it.\n", remote)
	case "PRIVATE", "INTERNAL":
	default:
		say("unrecognised gh answer [%s] for remote %s — visibility unverified", raw, remote)
	}
}
