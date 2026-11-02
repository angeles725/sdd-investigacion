package ensureremote

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// readVis is read_vis: PUBLIC, PRIVATE or INTERNAL when decided, else UNKNOWN(<typed state>). A stalled, failing or
// unrecognised probe is NEVER PRIVATE: the guard only passes on a literal PRIVATE. bound is the probe's bound in
// seconds, 20 when the probe never ran (GHV_DEFAULT_BOUND).
func (c *command) readVis() (vis string, bound int) {
	v, _ := c.d.gh.Probe(c.ghOpts("", 0), c.owner+"/"+c.repo)
	bound = v.Bound.Seconds
	if bound == 0 {
		bound = probeBoundFloor
	}
	if v.State.Decided() {
		return string(v.State), bound
	}
	return "UNKNOWN(" + string(v.State) + ")", bound
}

// createAndPush is LAYER 1 + 5: create PRIVATE, then VERIFY visibility BEFORE ANY push. The push is textually after
// and guarded by the confirmed-private check.
func (c *command) createAndPush() int {
	slugName := c.owner + "/" + c.repo
	c.out(">> creating PRIVATE remote %s\n", slugName)

	// `gh repo create` has its OWN knob (RSDD_GH_CREATE_TIMEOUT, default 60): a create is a write plus a remote add.
	cr, _ := c.d.gh.Run(c.ghOpts(createKnob, createDefault), "repo", "create", slugName, "--private", "--source", c.target,
		"--remote", "origin", "--disable-wiki")
	c.pass(Out{Stdout: cr.Stdout, Stderr: cr.Stderr})
	if cr.Bound.Bad {
		c.errf("   note: %s='%s' is not a positive integer — using the default %ds\n", createKnob, c.s.Env(createKnob), createDefault)
	}
	if cr.State != gh.StateOK {
		// A timeout, an output cap or a probe failure leave the outcome UNKNOWN (the repo and the origin may exist):
		// they are read back and cleaned up like a timeout. Any other state is a plain failure.
		if cr.State != gh.StateTimeout && cr.State != gh.StateOutputCap && cr.State != gh.StateProbeFailed {
			return c.refuse(exitTooling, "REFUSED: gh repo create failed.")
		}
		if code, done := c.createTimedOut(slugName, cr); done {
			return code
		}
	}

	vis, _ := c.readVis()
	if vis != "PRIVATE" {
		c.errf("   visibility read back as '%s' — forcing --visibility private once\n", vis)
		// Bounded. The outcome is deliberately NOT trusted either way: a timed-out or failed edit is typed DEGRADED
		// and the re-read below is the only authority on what the repo is now.
		er, _ := c.d.gh.Run(c.ghOpts("", 0), "repo", "edit", slugName, "--visibility", "private")
		if er.State != gh.StateOK {
			if er.State == gh.StateTimeout {
				c.errf("   DEGRADED: gh repo edit timed out after %ds — outcome unknown, re-reading visibility\n", er.Bound.Seconds)
			} else {
				c.errf("   DEGRADED: gh repo edit failed (exit %d) — re-reading visibility\n", er.RC)
			}
		}
		vis, _ = c.readVis()
	}
	if vis != "PRIVATE" {
		c.errf("!! HARD ABORT: a non-private repo exists at https://github.com/%s — DELETE IT MANUALLY\n", slugName)
		c.errf("   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing.\n")
		// The removal's status is CHECKED: a failed removal that leaves an origin behind is named, never silent.
		if rm := c.git("remote", "remove", "origin"); rm.RC != 0 {
			if left, ok := c.originURL(); ok {
				c.errf("   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the local origin %s is STILL configured and points at a NON-PRIVATE repo. Remove it by hand (git -C \"%s\" remote remove origin).\n", left, c.target)
			}
		}
		return exitUnverified
	}

	// Push is textually AFTER and GUARDED BY the confirmed-private check above. --no-follow-tags keeps annotated tag
	// messages (which may contain secrets) from being pushed when push.followTags=true is set.
	c.out(">> confirmed PRIVATE — pushing corpus\n")
	// The push is the one run with no bound and no buffering: like the bash it streams straight to the caller's
	// stdout and stderr and reads the caller's stdin, so a slow push or a credential prompt behaves as before.
	argv := []string{"git", "-C", c.target, "push", "-u", "origin", "HEAD", "--no-follow-tags"}
	if rc := c.d.stream(argv, c.environ, c.s.In, c.s.Out, c.s.Err); rc != 0 {
		return c.refuse(exitTooling, "REFUSED: push failed.")
	}
	c.out("== ensure-remote: private remote ready at https://github.com/%s ==\n", slugName)
	return 0
}

// createTimedOut handles a `gh repo create` that hit its bound. The outcome is UNKNOWN: the repo may exist on GitHub
// and `--source --remote origin` may already have added the local origin. Observe both READ-ONLY, name the partial
// state, and never assume either way. done is false when the run falls through to the normal verify-then-push guard
// (an origin was added and the repo is not UNKNOWN).
func (c *command) createTimedOut(slugName string, cr gh.RunResult) (code int, done bool) {
	cur, hasOrigin := c.originURL()
	have := "absent"
	if hasOrigin {
		have = "configured"
	}
	tvis, bound := c.readVis()
	what := "timed out"
	if cr.State != gh.StateTimeout {
		what = "did not finish (" + string(cr.State) + ")"
	}
	c.errf("DEGRADED: gh repo create %s after %ds — PARTIAL-STATE local origin=%s, remote %s visibility=%s\n", what, bound, have, slugName, tvis)
	if strings.HasPrefix(tvis, "UNKNOWN") {
		// Visibility could not be read: the repo may exist with ANY visibility. Never adopt it and never call a
		// re-run safe. Remove the origin the create may have added so a re-run cannot short-circuit onto an unverified
		// repo; the removal's exit status is CHECKED, a failed removal leaves the origin in place and the message says so.
		left := false
		if hasOrigin && c.git("remote", "remove", "origin").RC != 0 {
			left = true
		}
		if left {
			c.errf("   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the unverified local origin %s is STILL configured; the repo %s may exist with an unknown visibility; nothing pushed.\n", cur, slugName)
			c.errf("   Remove it by hand (git -C \"%s\" remote remove origin) — a re-run would short-circuit onto that unverified origin.\n", c.target)
		} else {
			c.errf("   PARTIAL-STATE UNKNOWN: the repo %s may exist with an unknown visibility; any local origin was removed; nothing pushed.\n", slugName)
		}
		c.errf("   Next: check https://github.com/%s by hand (delete it, or set it private) BEFORE re-running ensure-remote.sh — a re-run is NOT safe until its visibility is known.\n", slugName)
		return exitTooling, true
	}
	if hasOrigin {
		// Adopt: fall through to the SAME create-then-verify guard. It re-reads visibility, forces private once,
		// hard-aborts (exit 6, origin removed, no push) unless the repo is confirmed PRIVATE, and only then pushes.
		c.errf("   next: local origin is configured — verifying the existing remote below; it is pushed ONLY if confirmed PRIVATE.\n")
		return 0, false
	}
	if tvis == "PRIVATE" {
		c.errf("   the repo exists PRIVATE but no local origin was added. Nothing pushed. Next: git -C \"%s\" remote add origin https://github.com/%s.git\n", c.target, slugName)
		c.errf("   and push it yourself (git push -u origin HEAD --no-follow-tags); re-running this script would fail on 'repo already exists'.\n")
		return exitTooling, true
	}
	c.errf("!! HARD ABORT: a non-private repo (%s) exists at https://github.com/%s — DELETE IT MANUALLY\n", tvis, slugName)
	c.errf("   (this wrapper has NO delete_repo scope). Nothing pushed; no local origin was added.\n")
	return exitUnverified, true
}
