package gate

import (
	"fmt"
	"io"
	"math"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// RunReturnToken is `rsdd gate return-token [--toolbelt DIR] [<target>]`, the port of toolbelt/return-token-gate.sh
// (kit issue #1706, slice 2; the decision order and the token grammar are in that script's header, kept as the
// reference until phase 8). It is a Claude Code Stop hook: it reads the hook JSON on stdin, blocks ONCE when the
// final report's continuation token is missing or differs from the provider-issued one, and ALWAYS returns 0.
// BLOCK is {"decision":"block","reason":...} on stdout; ALLOW is empty stdout. Every decision except "not a corpus
// target" prints one typed stderr line `return-token-gate: state=... branch=... target=<basename>`.
//
// --toolbelt DIR names the directory holding research-sdd-status.sh, the one dependency that is still bash. The
// compatibility shim passes its own directory, so a copy of the toolbelt (the bash suite's stub case) runs its
// own sibling. Without the flag the toolbelt is the one of the resolved kit (core/kit ResolveKitScript).
//
// Deliberate differences from the bash, each pinned by a test: the `timeout` binary is not needed (the bound is
// native, so the bash "no 'timeout' command" degrade has no Go equivalent), the status call gets the process
// environment through proc.Spec{Env: nil}, and a toolbelt that cannot be resolved is one more typed degrade.
func RunReturnToken(args []string, s cli.Stdio) int {
	g := &rtGate{s: s, label: "?"}
	g.run(args)
	return cli.ExitOK
}

type rtGate struct {
	s     cli.Stdio
	label string
}

func (g *rtGate) log(format string, a ...any) {
	fmt.Fprintf(g.s.Err, "return-token-gate: %s target=%s\n", fmt.Sprintf(format, a...), g.label)
}

func (g *rtGate) degraded(why string) { g.log("state=allow branch=degraded (%s)", why) }

func (g *rtGate) run(args []string) {
	toolbelt, target := parseRTArgs(args)

	pr := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd)
	if _, err := pr.LookPath("jq"); err != nil { // RTG-JQ-PROBE
		g.degraded("jq missing — cannot read hook JSON")
		return
	}

	in, _ := io.ReadAll(g.s.In)
	vals, ok := decodeStream([]byte(stripNUL(string(in))))
	if !hookReadable(vals, ok) {
		g.degraded("hook JSON unreadable")
		return
	}
	sessionID := hookField(vals, "session_id", "")
	stopActive := hookField(vals, "stop_hook_active", "false")
	transcript := hookField(vals, "transcript_path", "")
	cwd := hookField(vals, "cwd", "")

	targetArg := target
	if targetArg == "" {
		targetArg = cwd
	}
	if targetArg == "" {
		g.degraded("no target — neither an argument nor a hook cwd")
		return
	}
	tgt, isDir := cdLogical(targetArg, g.s.Cwd)
	if !isDir {
		g.degraded("no target — not a directory: " + targetArg)
		return
	}
	g.label = path.Base(tgt)

	if stopActive == "true" { // RTG-LOOP-SAFETY
		g.log("state=allow branch=loop-safety stop_hook_active=true")
		return
	}

	states, _ := kit.ListStateFiles(tgt)
	if len(states) == 0 { // RTG-NOT-TARGET
		return
	}

	report, why := g.finalReport(transcript)
	if why != "" {
		g.degraded(why)
		return
	}
	reported, override := reportTokens(report)

	if override != "" { // RTG-OVERRIDE
		g.log("state=allow branch=override reason=%s", override)
		return
	}

	emitted, why := g.emittedToken(toolbelt, tgt)
	if why != "" {
		g.degraded(why)
		return
	}

	if strings.HasPrefix(emitted, "return-token: unavailable") { // RTG-UNAVAILABLE-ALLOW
		g.log("state=allow branch=unavailable %s", strings.TrimPrefix(emitted, "return-token: "))
		return
	}

	stateDir := filepath.Join(tgt, ".claude")
	sid := sidSafe(sessionID, g.utf8Locale())
	marker := filepath.Join(stateDir, markerPrefix+sid)
	if sid != "" && markerHas(marker, emitted) { // RTG-BLOCK-ONCE
		g.log("state=allow branch=block-once session=%s", sid)
		return
	}

	expected := strings.TrimPrefix(emitted, "return-token: ")
	if reported != "" && reported == expected { // RTG-COMPARE
		g.log("state=allow branch=match")
		return
	}

	branch, reason := "mismatch", ""
	if reported == "" { // RTG-MISSING-BRANCH
		branch = "missing"
		reason = "The final report carries no continuation token (PROMPT-LOOP RETURN CONTRACT: end every report with exactly one). Do not compose it; copy this provider-issued line verbatim as the last line of your report:\n\n" +
			emitted + "\n\nIf ending without the token is deliberate, add a line 'return-token-override: <reason>'. This gate blocks once per session and token."
	} else {
		reason = "The final report's continuation token does not match the provider-issued one (reported: '" + reported +
			"'). Do not compose the token; replace it with this line, copied verbatim:\n\n" + emitted +
			"\n\nIf the difference is deliberate, add a line 'return-token-override: <reason>'. This gate blocks once per session and token."
	}
	if sid != "" {
		if markerAppend(stateDir, marker, emitted) == nil {
			maxAge := envCount(g.s.Env("RETURN_TOKEN_GATE_MARKER_MAX_AGE_DAYS"), 14, true)
			keep := envCount(g.s.Env("RETURN_TOKEN_GATE_MARKER_KEEP"), 50, false)
			if !pruneMarkers(stateDir, maxAge, keep, marker, g.s.Clock()) {
				fmt.Fprintf(g.s.Err, "return-token-gate: WARN: block-once marker prune failed under %s\n", stateDir)
			}
		} else {
			fmt.Fprintf(g.s.Err, "return-token-gate: WARN: block-once marker write failed (%s) — the block is still issued\n", marker)
		}
	}
	g.log("state=block branch=%s", branch)
	fmt.Fprint(g.s.Out, blockJSON(reason))
}

// parseRTArgs reads [--toolbelt DIR | --toolbelt=DIR] and the first other argument as the target. Nothing here can
// fail: a hook never errors on its arguments (the bash ignored extras too).
func parseRTArgs(args []string) (toolbelt, target string) {
	var rest []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--toolbelt" && i+1 < len(args):
			toolbelt = args[i+1]
			i++
		case strings.HasPrefix(a, "--toolbelt="):
			toolbelt = strings.TrimPrefix(a, "--toolbelt=")
		default:
			rest = append(rest, a)
		}
	}
	if len(rest) > 0 {
		target = rest[0]
	}
	return toolbelt, target
}

// cdLogical is `cd "$arg" && pwd`: the lexically cleaned logical path of an existing directory (the bash comment
// mentions -P, but the script uses plain `cd` and `pwd`, so symlinks are not resolved). A leading `-` is a cd option.
func cdLogical(arg, cwd string) (string, bool) {
	if strings.HasPrefix(arg, "-") {
		return "", false
	}
	abs := arg
	if !filepath.IsAbs(arg) {
		abs = cwd + "/" + arg
	}
	clean := path.Clean(abs)
	return clean, kit.IsDirOS(clean)
}

func (g *rtGate) utf8Locale() bool {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v := g.s.Env(k); v != "" {
			v = strings.ToLower(v)
			return strings.Contains(v, "utf-8") || strings.Contains(v, "utf8")
		}
	}
	return false
}

// finalReport is steps (4): the final report, or the typed reason it could not be read.
func (g *rtGate) finalReport(transcript string) (report, why string) {
	if transcript == "" || !readable(transcript) { // RTG-TRANSCRIPT-DEGRADED
		if transcript == "" {
			transcript = "no transcript_path in the hook JSON"
		}
		return "", "transcript unreadable: " + transcript
	}
	tb := tailBytes(g.s.Env("RETURN_TOKEN_GATE_TAIL_BYTES"))
	data, size := readTail(transcript, tb)
	window, truncated := tailWindow(data, tb, size) // RTG-TAIL-BOUND
	text, ok := lastReport([]byte(stripNUL(string(window))))
	if !ok {
		text = ""
	}
	text = cmdSub(text)
	if text == "" {
		suffix := ""
		if truncated {
			suffix = fmt.Sprintf(" (tail-bounded to %d bytes)", tb)
		}
		return "", "no assistant text in the transcript: " + filepath.Base(transcript) + suffix
	}
	return text, ""
}

// readTail reads the transcript, or only its last n bytes when it is longer (`tail -c n`): a session transcript of
// hundreds of megabytes must not be loaded. An unreadable file reads as empty.
func readTail(p string, n int64) (data []byte, size int64) {
	f, err := os.Open(p)
	if err != nil {
		return nil, 0
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return nil, 0
	}
	size = st.Size()
	off := int64(0)
	if size > n {
		off = size - n
	}
	data, err = io.ReadAll(io.NewSectionReader(f, off, size-off))
	if err != nil {
		return nil, 0
	}
	return data, size
}

// readable is `[ -r path ]` for a file the gate then reads.
func readable(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

// emittedToken runs `research-sdd-status.sh <target> --next --emit-token` and returns its last `return-token:`
// line, or the degraded reason (steps 6).
func (g *rtGate) emittedToken(toolbelt, tgt string) (emitted, why string) {
	status := ""
	if toolbelt != "" {
		status = toolbelt + "/research-sdd-status.sh"
	} else {
		p, _, err := kit.ResolveKitScript("toolbelt/research-sdd-status.sh", kit.Getenv(g.s.Env))
		if err != nil {
			return "", "status script unavailable: " + err.Error()
		}
		status = p
	}
	secs := g.s.Env("RETURN_TOKEN_GATE_TIMEOUT_SECS")
	if secs == "" {
		secs = "20"
	}
	out, rc, timedOut := g.runStatus(status, tgt, secs)
	if timedOut { // RTG-STATUS-TIMEOUT
		return "", "status --next timed out after " + secs + "s"
	}
	emitted = lastEmitted(cmdSub(out))
	if emitted == "" { // RTG-STATUS-DEGRADED
		return "", fmt.Sprintf("status produced no return-token line (rc=%d)", rc)
	}
	return emitted, ""
}

// runStatus is `timeout SECS bash STATUS TARGET --next --emit-token 2>/dev/null`: stdout, the exit code `timeout`
// would report (125 for a bad duration, 127 when bash cannot start, 128+N for a signal) and whether the bound hit.
func (g *rtGate) runStatus(status, tgt, secs string) (out string, rc int, timedOut bool) {
	d, ok := parseTimeout(secs)
	if !ok {
		return "", 125, false
	}
	bash, err := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd).LookPath("bash")
	if err != nil {
		return "", 127, false
	}
	// Env nil: exec.Cmd inherits the process environment, exactly like the child of the bash hook.
	res, err := proc.Run(proc.Spec{Argv: []string{bash, status, tgt, "--next", "--emit-token"}, Timeout: d, MaxBytes: 16 << 20})
	switch {
	case err != nil:
		return "", 127, false
	case res.Reason == proc.ReasonTimeout:
		return "", 124, true
	case res.ReturnCode < 0:
		return string(res.Stdout), 128 - res.ReturnCode, false
	}
	return string(res.Stdout), res.ReturnCode, false
}

// parseTimeout is GNU timeout's DURATION: a non-negative number with an optional s, m, h or d suffix; 0 disables
// the bound (here: a day). ok is false for what timeout rejects with its exit 125.
func parseTimeout(v string) (time.Duration, bool) {
	unit := time.Second
	if n := len(v); n > 0 {
		switch v[n-1] {
		case 's':
			v = v[:n-1]
		case 'm':
			unit, v = time.Minute, v[:n-1]
		case 'h':
			unit, v = time.Hour, v[:n-1]
		case 'd':
			unit, v = 24*time.Hour, v[:n-1]
		}
	}
	if v == "" || strings.ContainsAny(v[:1], "+-") {
		return 0, false
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil || f < 0 || math.IsNaN(f) {
		return 0, false
	}
	if f == 0 || f*float64(unit) > float64(24*time.Hour) {
		return 24 * time.Hour, true
	}
	d := time.Duration(f * float64(unit))
	if d <= 0 {
		d = time.Nanosecond
	}
	return d, true
}
