package gate

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// RunRetro is `rsdd gate retro [--toolbelt DIR] [--json] <target>`, the port of toolbelt/retro-gate.sh (kit issues
// #2367, #2368; perf #2168), the §18 Stop-hook body: it blocks once when research files advanced without a
// conforming retro. The bash script's header stays the reference for the contract until phase 8: it reads the Stop
// hook JSON on stdin, ALWAYS exits 0 in the default mode, prints BLOCK as {"decision":"block","reason":...} on
// stdout and ALLOW as nothing, and prints one typed state line on stderr. With --json stdout carries ONE
// research-sdd.retro-gate/v1 envelope instead, and the exit codes are 0 verdict, 1 operational failure, 2 usage
// error and 3 degraded (jq missing or without --argjson).
//
// --toolbelt DIR names the toolbelt the shim lives in: its lib/ must exist, verify-retro.sh and
// stage-retro-issues.sh (still run as bash, exactly as the old script ran them) are its siblings, and the kit root
// is its parent. Without the flag the toolbelt is the one of the resolved kit.
//
// Deliberate differences from the bash, each pinned by a test:
//   - the scans walk the tree natively instead of forking find, grep, basename and stat per path (#2168), and keep
//     the exact predicates of the old commands; the directory-symlink timeout is native, so the bash degrade for a
//     missing `timeout` binary has no Go equivalent;
//   - stdout is written when the command returns (the cli contract), so --json no longer reaches the reader
//     before issue seeding finishes;
//   - a find traversal error during issue seeding prints `find: ‘<path>’: <reason>` in the UTF-8 quoting of GNU find
//     whatever the locale; the usage line always names retro-gate.sh;
//   - a grep -o with several matches in one seeder summary reads the first match, where bash would fail the
//     arithmetic; the stop-log session id is sanitized per character in a UTF-8 locale and per byte otherwise,
//     like the return-token gate.
func RunRetro(args []string, s cli.Stdio) int { return runRetro(args, s, retroHooks{}) }

// retroHooks are the test seams of the gate; the zero value is production.
type retroHooks struct {
	// onEntry runs for every directory entry of a directory-symlink walk (tests make a walk slow).
	onEntry func(root, path string)
	// walkRC forces the status of the directory-symlink walk rooted at root (tests simulate a failing walk).
	walkRC func(root string) int
	// exit ends the process on SIGTERM/SIGINT; nil is os.Exit.
	exit func(code int)
	// nested replaces the nested-worktree probe (tests make it fail with a status the real probe cannot reach).
	nested func(root string) ([]string, error)
}

const (
	rgStopLogMax  = 400
	rgStopLogKeep = 200
	rgBigOutput   = 512 << 20
)

type retroGate struct {
	s     cli.Stdio
	hooks retroHooks

	toolbelt, kit string
	jsonMode      bool
	errRC         int

	target    string // TARGET: the logical absolute path
	branch    string // _STOP_BRANCH
	seed      string // _STOP_SEED
	sessionID string
	degraded  bool
	unverif   int // _unverified

	nw         []string // nested worktree roots (_nw_roots)
	sessionSHA string

	mu       sync.Mutex
	finished bool
}

func runRetro(args []string, s cli.Stdio, hooks retroHooks) int {
	g := &retroGate{s: s, hooks: hooks}
	return g.run(args)
}

func (g *retroGate) errf(format string, a ...any) { fmt.Fprintf(g.s.Err, format, a...) }

func (g *retroGate) env() []string {
	if g.s.Environ != nil {
		return g.s.Environ()
	}
	return nil
}

func (g *retroGate) runner() git.Runner {
	return git.Runner{Env: g.env(), MaxBytes: rgBigOutput, Now: g.s.Clock}
}

// gitLines is `git -C TARGET args 2>/dev/null` read line by line: the stdout whatever the status was (a failing
// git leaves a partial or empty list, which the bash loops read as such).
func (g *retroGate) gitLines(args ...string) []string {
	out, _ := g.runner().Run(g.target, args...)
	return kit.SplitLines(string(out))
}

func (g *retroGate) run(args []string) int {
	toolbelt := ""
	var pos []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			g.jsonMode = true
		case a == "--toolbelt" && i+1 < len(args):
			toolbelt = args[i+1]
			i++
		case strings.HasPrefix(a, "--toolbelt="):
			toolbelt = strings.TrimPrefix(a, "--toolbelt=")
		default:
			pos = append(pos, a)
		}
	}
	if g.jsonMode {
		g.errRC = cli.ExitOperational
	}
	if len(pos) != 1 {
		g.errf("Usage: retro-gate.sh [--json] <target>\nretro-gate: ERROR: missing <target>\n")
		if g.jsonMode {
			return cli.ExitUsage
		}
		return cli.ExitOK
	}
	tgt, isDir := cdLogical(pos[0], g.s.Cwd)
	if !isDir {
		g.errf("retro-gate: ERROR: target not found: %s\n", pos[0])
		return g.errRC
	}
	g.target = tgt

	if toolbelt == "" {
		if p, _, err := kit.ResolveKitScript("toolbelt/retro-gate.sh", kit.Getenv(g.s.Env)); err == nil {
			toolbelt = filepath.Dir(p)
		} else {
			toolbelt = "toolbelt"
		}
	}
	g.toolbelt = toolbelt
	g.kit = physical(filepath.Dir(toolbelt))

	g.branch = "error-helper"
	stop := g.watchSignals()
	defer stop()
	rc := g.body()
	g.mu.Lock()
	g.finished = true
	g.writeStopLog()
	g.mu.Unlock()
	return rc
}

// physical is `cd -P dir && pwd -P`, falling back to dir when it cannot be resolved.
func physical(dir string) string {
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		if a, err := filepath.Abs(r); err == nil {
			return a
		}
	}
	return dir
}

func (g *retroGate) body() int {
	for _, lib := range []string{g.toolbelt + "/lib/block-files.sh", g.toolbelt + "/lib/retro-status.sh"} {
		if st, err := os.Stat(lib); err != nil || !st.Mode().IsRegular() {
			g.errf("retro-gate: ERROR: missing helper %s\n", lib)
			return g.errRC
		}
	}
	g.branch = ""
	tname := baseName(g.target)

	pr := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd)
	if _, err := pr.LookPath("jq"); err != nil { // RG-JQ-PROBE
		g.branch = "degraded"
		g.errf("retro-gate: state=allow branch=degraded (jq missing — cannot read hook JSON) target=%s\n", tname)
		if g.jsonMode {
			g.errf("DEGRADED: jq not found; cannot read hook JSON or build the envelope\n")
			fmt.Fprint(g.s.Out, `{"schema":"research-sdd.retro-gate/v1","state":"degraded","reason":"jq not found; cannot read hook JSON or build the envelope","counts":{},"items":[]}`+"\n")
			return cli.ExitDegraded
		}
		return cli.ExitOK
	}
	if g.jsonMode && !g.jqHasArgjson() { // RG-JQ-CAPABILITY
		g.branch = "degraded"
		g.errf("retro-gate: state=allow branch=degraded (jq lacks --argjson — cannot build the envelope) target=%s\n", tname)
		g.errf("DEGRADED: jq lacks --argjson (jq >= 1.5 required)\n")
		fmt.Fprint(g.s.Out, `{"schema":"research-sdd.retro-gate/v1","state":"degraded","reason":"jq lacks --argjson (jq >= 1.5 required)","counts":{},"items":[]}`+"\n")
		return cli.ExitDegraded
	}

	in, _ := io.ReadAll(g.s.In)
	vals, ok := decodeStream([]byte(stripNUL(string(in))))
	stopActive := "false"
	if ok {
		g.sessionID = hookField(vals, "session_id", "")
		stopActive = hookField(vals, "stop_hook_active", "false")
	}

	if stopActive == "true" { // RG-LOOP-SAFETY
		g.branch = "loop-safety"
		g.errf("retro-gate: state=allow branch=loop-safety stop_hook_active=true target=%s\n", tname)
		g.verdictAllow("", "", "")
		return cli.ExitOK
	}

	stateDir := g.target + "/.claude"
	blockedFile := stateDir + "/.rsdd-retro-blocked-" + g.sessionID
	if g.sessionID != "" && isRegular(blockedFile) { // RG-BLOCK-ONCE
		g.branch = "block-once"
		g.errf("retro-gate: state=allow branch=block-once session=%s target=%s\n", g.sessionID, tname)
		g.verdictAllow("", "", "")
		return cli.ExitOK
	}

	g.probeNestedWorktrees(tname)

	sessionFile := stateDir + "/.rsdd-session-" + g.sessionID
	if g.sessionID != "" && isRegular(sessionFile) {
		if b, err := os.ReadFile(sessionFile); err == nil {
			g.sessionSHA = cmdSub(string(b))
		}
	}
	if g.sessionSHA == "" {
		g.errf("retro-gate: WARN: no session-start sha (session file absent/empty); degraded check\n")
		g.degraded = true
	}
	if !g.degraded {
		if _, err := g.runner().Run(g.target, "rev-parse", "-q", "--verify", g.sessionSHA+"^{commit}"); err != nil {
			g.errf("retro-gate: WARN: session-start sha %s unresolvable; degraded check\n", g.sha12())
			g.degraded = true
		}
	}
	checkMode := "session-sha"
	if g.degraded {
		checkMode = "mtime-fallback"
	}

	hasChanged := g.detectChanges(sessionFile)

	if !g.degraded && !hasChanged { // RG-ALLOW-NO-CHANGE
		g.branch = "no-change"
		g.errf("retro-gate: state=allow branch=no-change target=%s\n", tname)
		g.verdictAllow("session-sha", "", "")
		return cli.ExitOK
	}

	nbMtime := int64(0)
	if g.degraded {
		nbMtime = g.newestBlockMtime()
	}

	newest, nrMtime := g.newestRetro(sessionFile)

	retroLabel := newest
	if retroLabel == "" {
		retroLabel = "(none)"
	}
	nChanged := "unknown (degraded)"
	if !g.degraded {
		nChanged = "1 changed"
		if !hasChanged {
			nChanged = "0 changed"
		}
	}
	verifyRetro := g.toolbelt + "/verify-retro.sh"
	suggest := g.target + "/retros/" + g.s.Clock().Format("2006-01-02") + "-<focus>.md"
	tmpl := g.kit + "/templates/retro.template.md"
	reason := ""

	switch {
	case !g.degraded && newest == "":
		reason = "§18 retro pending for " + tname + ": run the SELF-RETROSPECTIVE (fresh-context retro agent) from " + tmpl + " → " + suggest + ", then stop. Checked: research file(s) changed, newest retro: none added this session. Template: " + tmpl
	case g.degraded && nrMtime == 0:
		reason = "§18 retro pending for " + tname + ": run the SELF-RETROSPECTIVE (fresh-context retro agent) from " + tmpl + " → " + suggest + ", then stop. Checked: research file(s) changed, newest retro: none. Template: " + tmpl
	case g.degraded && nbMtime > nrMtime:
		reason = "§18 retro pending for " + tname + ": newest retro " + baseName(newest) + " is OLDER than newest changed block. Run the SELF-RETROSPECTIVE from " + tmpl + " → " + suggest + ", then stop. Template: " + tmpl
	default:
		if isRegular(verifyRetro) { // RG-VERIFY-RETRO
			out, vrc := g.bashCapture(verifyRetro, newest)
			if vrc == 0 {
				g.branch = "retro-conforming"
				g.errf("retro-gate: state=allow branch=retro-conforming retro=%s target=%s\n", baseName(newest), tname)
				// The envelope goes out BEFORE seeding in the bash; here stdout is flushed when the command returns.
				g.verdictAllow(checkMode, baseName(newest), "")
				g.runIssueSeeding()
				return cli.ExitOK
			}
			reason = "§18 retro pending for " + tname + ": " + baseName(newest) + " is non-conforming. Fix it (from " + tmpl + ") — missing elements: " + out
		} else {
			g.branch = "no-verifier"
			g.unverif = 1
			g.errf("retro-gate: state=allow branch=no-verifier (verify-retro.sh absent) target=%s\n", tname)
			g.verdictAllow(checkMode, baseName(newest), "")
			return cli.ExitOK
		}
	}

	if g.sessionID != "" { // block-once state file; failures are ignored like `|| true`
		_ = os.MkdirAll(stateDir, 0o777)
		_ = os.WriteFile(blockedFile, []byte(g.s.Clock().UTC().Format("2006-01-02T15:04:05Z")+"\n"), 0o666)
	}
	g.branch = "retro-pending"
	g.errf("retro-gate: state=block branch=retro-pending changed=%s retro=%s target=%s\n", nChanged, baseName(retroLabel), tname)
	if g.jsonMode {
		g.emitEnvelope("block", checkMode, lastSegment(newest), reason)
	} else {
		fmt.Fprintf(g.s.Out, "{\"decision\":\"block\",\"reason\":\"%s\"}\n", escapeReason(reason))
	}
	return cli.ExitOK
}

// jqHasArgjson is `jq -n --argjson x 1 '$x'`: the capability the --json envelope needs.
func (g *retroGate) jqHasArgjson() bool {
	res, err := proc.Run(proc.Spec{Argv: []string{"jq", "-n", "--argjson", "x", "1", "$x"}, Env: g.env(), Timeout: 30 * time.Second, MaxBytes: 1 << 20, Now: g.s.Clock})
	return err == nil && res.Reason == "" && res.ReturnCode == 0
}

// sha12 is ${_session_sha:0:12}, in characters in a UTF-8 locale.
func (g *retroGate) sha12() string {
	if envUTF8(g.s.Env) {
		r := []rune(g.sessionSHA)
		if len(r) > 12 {
			r = r[:12]
		}
		return string(r)
	}
	if len(g.sessionSHA) > 12 {
		return g.sessionSHA[:12]
	}
	return g.sessionSHA
}

// probeNestedWorktrees is the nested-worktree probe (#1223): a failed or incomplete one keeps the roots found so far
// and is never silent, and it can never turn into an allow (a false BLOCK is recoverable, a false ALLOW is not).
func (g *retroGate) probeNestedWorktrees(tname string) {
	probe := kit.NestedWorktreeRoots
	if g.hooks.nested != nil {
		probe = g.hooks.nested
	}
	roots, err := probe(g.target)
	g.nw = roots
	if err == nil {
		return
	}
	g.unverif = 1
	g.errf("%s\n", err.Error()) // the lib prints its own typed WARN
	if rc := kit.RC(err); rc != 3 {
		g.errf("retro-gate: WARN: nested-worktree probe failed (rc=%d) for %s — worktree copies may be counted\n", rc, tname)
	}
}

func (g *retroGate) inNested(p string) bool { return kit.PathInNestedWorktree(p, g.nw) }

func (g *retroGate) watchSignals() func() {
	return startSignalWatch(g)
}

// kill is the SIGTERM/SIGINT handler: tag the stop-log line branch=killed, then end the process with the shell's
// code for the signal (143 / 130). It runs once, and never after the normal exit path took over.
func (g *retroGate) kill(code int) {
	g.mu.Lock()
	if g.finished {
		g.mu.Unlock()
		return
	}
	g.finished = true
	g.branch = "killed"
	g.writeStopLog()
	g.mu.Unlock()
	exit := g.hooks.exit
	if exit == nil {
		exit = os.Exit
	}
	exit(code)
}

// ── small helpers ────────────────────────────────────────────────────────────

func isRegular(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// path0Base is ${TARGET##*/}: everything after the last slash ("" for "/").
func path0Base(p string) string { return p[strings.LastIndex(p, "/")+1:] }

// baseName is coreutils basename: trailing slashes dropped, "/" for a path of slashes, "" for "".
func baseName(p string) string {
	if p == "" {
		return ""
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
		return "/"
	}
	return t[strings.LastIndex(t, "/")+1:]
}

// lastSegment is ${p##*/}.
func lastSegment(p string) string { return p[strings.LastIndex(p, "/")+1:] }
