package skilldrift

import (
	"bytes"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/verify-skill-drift-hook.sh, the SessionStart hook:
//
//	rsdd verify skill-drift-hook
//
// It runs `verify skill-drift --all`, then `research-sdd-install.sh --verify` (kit issue #1702: bundle digest and kit-checkout
// staleness) and the kit-staleness check (kit issue #2130), and is SILENT (no output) when every installed harness is in sync or
// absent and --verify has nothing to flag. Otherwise it prints the SessionStart envelope whose additionalContext is a header
// and the findings. Like the script it always exits 0: a hook never fails the session.
//
// Budget (openspec/specs/kit-session-cost/spec.md: SessionStart output < 8,000 characters in total): the --verify part
// contributes at most 4 degraded/behind lines of at most 170 bytes (SENTINEL-VERIFY-CAP) and, per drifted harness, a header, 3
// entries of at most 280 characters, a `(+N more ...)` line and a kept-hand-edit line of at most 160: ~1,150 characters per
// harness. The staleness check adds at most one stale line of 200 characters plus two invalid-threshold notes.
//
// Seams: RESEARCH_SDD_INSTALL_VERIFY_CMD overrides the install --verify command; RESEARCH_SDD_KIT_STALE_CHECK=off opts out of
// the staleness check; RESEARCH_SDD_KIT_DIR overrides the kit directory. The hook sits next to the drift command in the
// toolbelt directory the shim hands over in RSDD_TOOLBELT_DIR.

const (
	defaultVerifyTimeout = 10
	timeoutVarName       = "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"
)

// hookDeps are the pieces a test replaces: the drift half, and the reader of a file's modification time.
type hookDeps struct {
	drift func(args []string, s cli.Stdio) int
	mtime func(path string) (int64, error)
}

// RunHook is the `verify skill-drift-hook` command.
func RunHook(args []string, s cli.Stdio) int { return runHook(s, hookDeps{drift: RunDrift}) }

func runHook(s cli.Stdio, d hookDeps) int {
	if d.mtime == nil {
		d.mtime = osMtime
	}
	e := newEnvView(s)
	here := e.get(selfDirKey)
	if here == "" {
		// a hook never fails the session, and a missing piece announces itself instead of meaning empty stdout (#1877)
		writeSessionStart(s.Out, "ERROR: verify-skill-drift-hook could not run: "+selfDirKey+" is unset (run through toolbelt/verify-skill-drift-hook.sh)\n")
		return 0
	}
	if p, ok := physicalDir(here); ok {
		here = p
	}

	// the drift half: stdout and stderr of `verify-skill-drift.sh --all` on one stream, as `2>&1` made them
	var buf bytes.Buffer
	ds := s
	ds.Out, ds.Err = &buf, &buf
	rc := d.drift([]string{"--all"}, ds)
	out := trimNL(buf.String())

	extra, vrc, skipped := verifyHalf(e, s, here)
	extra = kitHalf(e, here, s, d, extra, vrc, skipped)

	if rc == 0 && extra == "" {
		return 0 // all in-sync / all absent, nothing to flag: stay completely silent
	}
	var msg string
	switch rc {
	case 0:
		msg = "WARN: research-sdd install --verify reports issues — see lines below"
	case 1:
		msg = "WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown"
	default:
		msg = "ERROR: verify-skill-drift.sh could not run for one or more harnesses — check kit install/adapters.sh"
	}
	if extra != "" {
		if out != "" {
			out += "\n"
		}
		out += extra
	}
	writeSessionStart(s.Out, msg+"\n"+out)
	return 0
}

// verifyTimeout validates RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT BEFORE any use: only 1..6 decimal digits with a value >= 1 are
// accepted (SENTINEL-VT-VALIDATE). Anything else gives the default and a typed note.
func verifyTimeout(e envView) (vt int, note string) {
	v, set := e.lookup(timeoutVarName)
	if !set {
		return defaultVerifyTimeout, ""
	}
	if v != "" && len(v) < 7 && strings.TrimLeft(v, "0123456789") == "" {
		if n, _ := strconv.Atoi(v); n >= 1 {
			return n, ""
		}
	}
	if v == "" { // set-but-empty reads better as '(empty)' than as ''
		return defaultVerifyTimeout, "verify: invalid " + timeoutVarName + " (empty), using 10s"
	}
	return defaultVerifyTimeout, "verify: invalid " + timeoutVarName + "='" + sanitize(v) + "', using 10s"
}

// verifyHalf runs install --verify and turns its output into the findings of the report. skipped is the script's extra_skip: the
// run was not made. It never is here, as the run is always bounded; the variable stays so the staleness half reads like the script.
func verifyHalf(e envView, s cli.Stdio, here string) (extra string, vrc int, skipped bool) {
	vcmd := e.get("RESEARCH_SDD_INSTALL_VERIFY_CMD")
	if vcmd == "" {
		vcmd = filepath.Join(here, "..", "install", "research-sdd-install.sh")
	}
	if !isExec(vcmd) {
		return "verify: install --verify could not run (not executable: " + filepath.Base(vcmd) + ")", 0, false
	}
	vt, vnote := verifyTimeout(e)
	r := runVerify(e, vcmd, s.Cwd, vt)
	vrc = r.rc
	if r.noTemp {
		if vnote != "" {
			vnote += "\n"
		}
		vnote += "verify: no mktemp - a stalled grandchild of install --verify is not bounded"
	}
	// only findings: harness drift / degraded and kit behind. match, absent and current stay silent; a kit `degraded` (tarball
	// install, no upstream) is un-clearable at session start (SENTINEL-KIT-BEHIND-ONLY)
	extra = findings(r.out)
	if drift := driftReport(r.out); drift != "" {
		if extra != "" {
			extra = drift + "\n" + extra
		} else {
			extra = drift
		}
	}
	// anti-silent-zero: a failing --verify that printed no typed finding must still be surfaced
	switch {
	case vrc == 124:
		timedOut := "verify: install --verify timed out (" + timeoutVarName + ", default 10s; on the pure-bash watchdog path the bound is that value plus up to ~0.5 s of sleep-probe time)"
		if extra != "" {
			timedOut += "\n" + extra
		}
		extra = timedOut
	case extra == "" && vrc != 0:
		extra = fmt.Sprintf("verify: install --verify exited %d with no typed line", vrc)
	}
	if vnote != "" {
		if extra != "" {
			extra += "\n"
		}
		extra += vnote
	}
	return extra, vrc, false
}

// kitHalf runs the staleness check (when it is not opted out, install --verify did not time out and ran) and merges it into extra.
func kitHalf(e envView, here string, s cli.Stdio, d hookDeps, extra string, vrc int, skipped bool) string {
	if e.get("RESEARCH_SDD_KIT_STALE_CHECK") == "off" || vrc == 124 || skipped { // SENTINEL-KIT-STALE-SKIP-TIMEOUT
		return extra
	}
	k := kitStale(e, here, s.Clock, d.mtime)
	if k.state == "ok" || k.state == "stale" {
		// drop install --verify's behind line (any behind > 0) so the thresholds govern; a diverged one stays and wins
		var keep []string
		diverged := false
		for _, l := range strings.Split(extra, "\n") {
			switch {
			case strings.HasPrefix(l, "verify kit status=behind") && strings.Contains(l, "diverged"):
				diverged = true
				keep = append(keep, l)
			case strings.HasPrefix(l, "verify kit status=behind"): // SENTINEL-KIT-STALE-DEDUPE
			default:
				keep = append(keep, l)
			}
		}
		extra = strings.Join(keep, "\n")
		if diverged {
			k.line = ""
		}
		// a non-zero install --verify exit must never be silenced by the dedupe (its only typed line may have been the behind line)
		if extra == "" && vrc != 0 { // SENTINEL-KIT-STALE-RC
			extra = fmt.Sprintf("verify: install --verify exited %d with no typed line", vrc)
		}
	}
	for _, l := range []string{k.note, k.line, k.deg} {
		if l != "" {
			if extra != "" {
				extra += "\n"
			}
			extra += l
		}
	}
	return extra
}
