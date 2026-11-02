// Package ensureremote is `rsdd corpus ensure-remote`: the port of toolbelt/ensure-remote.sh (kit issue #2460), the
// only sanctioned way a Research-SDD corpus touches GitHub. The corpora decompile proprietary systems, so a public
// repository would leak the research: the command makes a public remote unreachable by construction.
//
// THE SIX-LAYER PRIVATE GUARD (each independently blocks a public leak):
//
//  1. NO PUBLIC CODE PATH: `--private` is hard-coded on the single `gh repo create`; no flag or variable flips it.
//  2. A PERSONAL ACCOUNT: the owner comes from `gh api user` and is refused when it is an organization (orgs can
//     carry a default-public creation policy) or when its type cannot be verified.
//  3. CONSENT GATE: refused unless --yes or RSDD_ALLOW_REMOTE=1; no network call happens before it.
//  4. PRE-PUSH SECRET SWEEP: (a) .gitignore is seeded with secret-bearing paths and committed; the working tree must
//     be clean; (b) scan-secrets.sh --committed must pass; (c) no git-TRACKED secret-type file may exist, except
//     paths an explicit allow list (.research-sdd/secret-files.conf) names AND whose every committed blob is
//     positively identified as public material (classify.go, allow.go).
//  5. CREATE THEN VERIFY: after create the visibility is read back; anything but a literal PRIVATE forces one
//     `--visibility private` and a re-read; still not private is a HARD ABORT (origin removed, exit 6, no push).
//  6. IDEMPOTENT: an origin that already resolves short-circuits everything.
//
// Exit: 0 remote present (created and pushed, or already there) - 2 bad args or not a git repository (also a
// malformed allow list) - 3 no consent - 4 owner is an organization - 5 secret leak, refused to push - 6
// visibility verification failed, HARD ABORT, no push - 7 tooling missing or a git/gh operation failed - 8 dirty
// working tree.
//
// Differences from the bash, none of them a loosened guard:
//   - the command is `rsdd corpus ensure-remote`; the shim passes --toolbelt (its own directory) as the VERY FIRST
//     argument so the sibling scan-secrets.sh is found beside the shim. Anywhere else --toolbelt is an unknown flag
//     (exit 2), as in the bash where the scanner can never be swapped. A call without --toolbelt is refused (exit 2,
//     before any git or gh call), and a --toolbelt directory without ensure-remote.sh is refused (exit 7): the
//     scanner is only ever the one beside the shim, never one found through RESEARCH_SDD_KIT;
//   - the "looks like text" test uses the ASCII class [[:alnum:]], stricter than the locale-dependent bash one;
//   - git, the scanner and the `gh api` owner lookups were unbounded in the bash and are bounded here (git and the
//     scanner one hour, the owner lookups by RSDD_GH_TIMEOUT); the final `git push` is the exception: unbounded and
//     streamed with the caller's stdin, stdout and stderr, as in the bash; a bound hit fails closed like any other failure;
//   - blobs are classified in memory, so the mktemp copy, its EXIT/INT/TERM cleanup trap and the base64/od/mktemp
//     tool probes of the bash have no counterpart;
//   - no GHV_NOTE line: the bash prints it only when the watchdog bounds gh, which core/gh replaces;
//   - the DEGRADED create-timeout line reports the bound of the read-back probe, not of the create: the bash prints
//     GHV_BOUND after the read-back overwrote it. Kept byte for byte (see TestCreateTimeoutReportsTheProbeBound).
//   - the bash ignores the exit status of `gh api user` and uses whatever it printed; so does this port.
package ensureremote

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// Exit statuses of the legacy script.
const (
	exitUsage       = 2
	exitNoConsent   = 3
	exitOrg         = 4
	exitLeak        = 5
	exitUnverified  = 6
	exitTooling     = 7
	exitDirtyTree   = 8
	usageLine       = "usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]"
	createKnob      = "RSDD_GH_CREATE_TIMEOUT"
	createDefault   = 60
	probeBoundFloor = 20 // GHV_DEFAULT_BOUND of the bash probe
)

// secretPatterns are the paths the seeded .gitignore keeps out of the corpus (REDACTION CHECKLIST of PROMPT-LOOP).
var secretPatterns = []string{"security/", "licenses/", "certificates/", "*.pem", "*.der", "*.key", "*.p12", "*.pfx",
	"id_rsa*", "keystore/", "keyring/", "*.jks", "*.keystore"}

// trackedPathspecs are the git pathspecs Layer 4c refuses when tracked (git's `*` crosses `/`).
var trackedPathspecs = []string{"*.pem", "*.der", "*.key", "*.p12", "*.pfx", "id_rsa*", "*.jks", "*.keystore",
	"security/*", "licenses/*", "certificates/*", "keystore/*", "keyring/*"}

// Run is the Main contract of `rsdd corpus ensure-remote`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, realDeps()) }

type command struct {
	s       cli.Stdio
	d       deps
	environ []string
	target  string
	owner   string
	repo    string
}

func (c *command) out(format string, a ...any)  { fmt.Fprintf(c.s.Out, format, a...) }
func (c *command) errf(format string, a ...any) { fmt.Fprintf(c.s.Err, format, a...) }

// refuse writes the lines to stderr and returns code.
func (c *command) refuse(code int, lines ...string) int {
	for _, l := range lines {
		fmt.Fprintln(c.s.Err, l)
	}
	return code
}

// git is `git -C <target> <args>`; pre are options that go before -C.
func (c *command) git(args ...string) Out { return c.gitBound(shortBound, nil, args...) }

func (c *command) gitBound(timeout time.Duration, pre []string, args ...string) Out {
	argv := append(append([]string{"git"}, pre...), "-C", c.target)
	return c.d.run(Cmd{Argv: append(argv, args...), Env: c.environ, Timeout: timeout})
}

// pass writes a run's own output through, as the bash lets a child write to the terminal.
func (c *command) pass(o Out) {
	_, _ = c.s.Out.Write(o.Stdout)
	_, _ = c.s.Err.Write(o.Stderr)
}

func trimNL(b []byte) string { return strings.TrimRight(string(b), "\n") }

func (c *command) ghOpts(knob string, dflt int) gh.Options {
	return gh.Options{Env: c.environ, Knob: knob, Default: dflt}
}

func execute(args []string, s cli.Stdio, d deps) int {
	c := &command{s: s, d: d, environ: s.Environ()}
	var target, name, toolbelt string
	consent := false
	// --toolbelt DIR is the shim's own injection, so it is honoured ONLY as the very first argument; anywhere else
	// it is an unknown flag, exactly as in the bash, where the scanner is always the one beside the script.
	if len(args) > 0 && args[0] == "--toolbelt" {
		if len(args) < 2 {
			return c.refuse(exitUsage, "REFUSED: --toolbelt requires a value")
		}
		toolbelt, args = args[1], args[2:]
	}
	for i := 0; i < len(args); {
		switch a := args[i]; {
		case a == "--yes":
			consent = true
			i++
		case a == "--name":
			if len(args)-i < 2 {
				return c.refuse(exitUsage, "REFUSED: "+a+" requires a value")
			}
			name = args[i+1]
			i += 2
		case strings.HasPrefix(a, "-"):
			return c.refuse(exitUsage, "unknown flag: "+a)
		default:
			target = a
			i++
		}
	}
	if target == "" {
		return c.refuse(exitUsage, usageLine)
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(s.Cwd, target)
	}
	if fi, err := os.Stat(target); err != nil || !fi.IsDir() {
		return c.refuse(exitUsage, usageLine)
	}
	c.target = filepath.Clean(target)
	if toolbelt == "" {
		// The scanner is only ever the one beside the shim: no RESEARCH_SDD_KIT or default-checkout fallback.
		return c.refuse(exitUsage, "REFUSED: --toolbelt DIR missing — run toolbelt/ensure-remote.sh; the secret scanner is only the one beside that script.")
	}

	// the target must already be a git repo (research-sdd-init.sh runs `git init` in it)
	if o := c.git("rev-parse", "--git-dir"); o.RC != 0 {
		return c.refuse(exitUsage, "REFUSED: "+c.target+" is not a git repository — run research-sdd-init.sh first.")
	}

	// LAYER 6: idempotent, an existing origin short-circuits everything (no duplicate repo)
	if url, ok := c.originURL(); ok {
		c.out("ensure-remote: origin already set (%s) — nothing to do.\n", url)
		return 0
	}

	// LAYER 3: consent gate, before ANY network call
	if !consent && s.Env("RSDD_ALLOW_REMOTE") != "1" {
		return c.refuse(exitNoConsent,
			"REFUSED: creating a remote pushes the corpus to GitHub. Re-run with --yes (or RSDD_ALLOW_REMOTE=1)",
			"         when you consent to a PRIVATE GitHub remote for "+filepath.Base(c.target)+".")
	}
	if !d.hasTool("gh", c.environ) {
		return c.refuse(exitTooling, "REFUSED: gh CLI not found — cannot create a remote.")
	}

	// LAYER 2: force a PERSONAL account (refuse an organization owner)
	res, _ := d.gh.Run(c.ghOpts("", 0), "api", "user", "-q", ".login")
	c.owner = trimNL(res.Stdout)
	if c.owner == "" {
		return c.refuse(exitTooling, "REFUSED: could not resolve your GitHub login (is gh authenticated?).")
	}
	res, err := d.gh.Run(c.ghOpts("", 0), "api", "users/"+c.owner, "-q", ".type")
	otype := trimNL(res.Stdout)
	if err != nil || res.State != gh.StateOK || otype == "" {
		return c.refuse(exitTooling, "REFUSED: could not verify that owner '"+c.owner+"' is a personal account (gh api failed).")
	}
	if otype == "Organization" {
		return c.refuse(exitOrg,
			"REFUSED: resolved owner '"+c.owner+"' is an ORGANIZATION — orgs can enforce a default-public creation",
			"         policy that would override --private. Create under a personal account instead.")
	}

	// repo name: default research-<basename>, slugified to [a-z0-9-]; --name overrides
	base := name
	if base == "" {
		base = "research-" + filepath.Base(c.target)
	}
	c.repo = slug(base)
	if c.repo == "" {
		return c.refuse(exitUsage, "REFUSED: could not derive a valid repo name.")
	}
	c.out("== ensure-remote: %s ==\n", filepath.Base(c.target))
	c.out("   owner : %s (personal)\n", c.owner)
	c.out("   repo  : %s (PRIVATE)\n", c.repo)

	c.seedGitignore()

	// LAYER 4b-pre: refuse on a dirty working tree (the committed scan must equal what is pushed). Fail closed: if
	// `git status` itself fails we cannot verify, so refuse.
	st := c.git("status", "--porcelain")
	if st.RC != 0 {
		return c.refuse(exitTooling,
			"REFUSED: could not check working tree status (git status --porcelain failed) — cannot",
			"         guarantee the committed-content scan matches what would be pushed.")
	}
	if trimNL(st.Stdout) != "" {
		return c.refuse(exitDirtyTree,
			"REFUSED: the working tree is dirty — a redaction applied to the working tree without",
			"         committing would pass the committed-content scan while the pushed HEAD still",
			"         carries the original secret. Commit, add to .gitignore, or stash with",
			"         'git stash -u', then re-run.")
	}

	if code := c.scan(toolbelt); code != 0 {
		return code
	}
	if code := c.trackedSecrets(); code != 0 {
		return code
	}
	return c.createAndPush()
}

// originURL is `url=$(git remote get-url origin) && [ -n "$url" ]`.
func (c *command) originURL() (string, bool) {
	o := c.git("remote", "get-url", "origin")
	url := trimNL(o.Stdout)
	return url, o.RC == 0 && url != ""
}

// slug lower-cases ASCII, turns every other byte outside [a-z0-9-] into '-' (tr -c works on bytes), squeezes runs of
// '-' and trims one from each end, exactly as the bash pipeline does.
func slug(s string) string {
	b := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		ch := s[i]
		switch {
		case 'A' <= ch && ch <= 'Z':
			ch += 'a' - 'A'
		case 'a' <= ch && ch <= 'z', '0' <= ch && ch <= '9', ch == '-':
		default:
			ch = '-'
		}
		if ch == '-' && len(b) > 0 && b[len(b)-1] == '-' {
			continue
		}
		b = append(b, ch)
	}
	out := string(b)
	out = strings.TrimPrefix(out, "-")
	return strings.TrimSuffix(out, "-")
}

// seedGitignore is LAYER 4a: seed .gitignore with secret-bearing paths BEFORE the remote exists, and commit it so
// the pushed HEAD carries the patterns (best effort: a nothing-to-commit case never aborts the guard).
func (c *command) seedGitignore() {
	gi := filepath.Join(c.target, ".gitignore")
	cur, _ := os.ReadFile(gi)
	var add strings.Builder
	if len(cur) > 0 && cur[len(cur)-1] != '\n' {
		add.WriteByte('\n')
		cur = append(cur, '\n')
	}
	have := map[string]bool{}
	for _, l := range strings.Split(string(cur), "\n") {
		have[l] = true
	}
	for _, pat := range secretPatterns {
		if !have[pat] {
			add.WriteString(pat + "\n")
		}
	}
	if add.Len() > 0 {
		if err := appendFile(gi, add.String()); err != nil {
			c.errf("ensure-remote: cannot update %s: %v\n", gi, err)
		}
	}
	dirty := c.git("diff", "--quiet", "--", ".gitignore").RC != 0
	if !dirty {
		o := c.git("ls-files", "--others", "--exclude-standard", "--", ".gitignore")
		_, _ = c.s.Err.Write(o.Stderr)
		dirty = trimNL(o.Stdout) != ""
	}
	if dirty {
		if a := c.git("add", ".gitignore"); a.RC == 0 {
			c.pass(a)
			c.pass(c.git("commit", "-q", "-m", "chore: ignore secret-bearing paths (ensure-remote)", "--", ".gitignore"))
		} else {
			c.pass(a)
		}
	}
}

// scan is LAYER 4b: the pre-push secret sweep (fail closed: no scanner means we cannot verify, so we refuse).
func (c *command) scan(toolbelt string) int {
	if !filepath.IsAbs(toolbelt) {
		toolbelt = filepath.Join(c.s.Cwd, toolbelt)
	}
	if fi, err := os.Stat(filepath.Join(toolbelt, "ensure-remote.sh")); err != nil || !fi.Mode().IsRegular() {
		return c.refuse(exitTooling, "REFUSED: "+toolbelt+" holds no ensure-remote.sh — the secret scanner must sit beside that script.")
	}
	scan := filepath.Join(toolbelt, "scan-secrets.sh")
	if fi, err := os.Stat(scan); err != nil || !fi.Mode().IsRegular() {
		return c.refuse(exitTooling, "REFUSED: scan-secrets.sh not found at "+scan+" — cannot verify committed content before push.")
	}
	o := c.d.run(Cmd{Argv: []string{"bash", scan, "--committed", c.target}, Env: c.environ, Timeout: longBound})
	switch o.RC {
	case 0:
		return 0
	case 1:
		return c.refuse(exitLeak,
			"REFUSED: scan-secrets.sh --committed found a high-confidence secret VALUE in the",
			"         committed history — NOT pushing. The git history must be rewritten to remove",
			"         the secret value (e.g. git filter-repo / BFG). Cite structure, not value —",
			"         SECRETS DISCIPLINE applies.")
	case 3:
		return c.refuse(exitTooling,
			"REFUSED: scan-secrets.sh --committed is degraded (git unavailable or no commits) —",
			"         cannot verify committed content before push.")
	}
	return c.refuse(exitTooling, fmt.Sprintf("REFUSED: scan-secrets.sh --committed failed (exit %d) — cannot verify committed content before push.", o.RC))
}

// appendFile appends s to path, creating it.
func appendFile(path, s string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, werr := io.WriteString(f, s)
	return errors.Join(werr, f.Close())
}
