package verify

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Port of research-sdd/toolbelt/verify-skill-drift-hook.sh, the SessionStart hook of verify skill-drift:
//
//	rsdd verify skill-drift --hook [<toolbelt-dir>]
//
// It runs the drift check for every harness (--all), then `research-sdd-install.sh --verify` (bundle drift,
// kit-checkout staleness) under a bound, and prints the SessionStart envelope when either has something to say;
// otherwise it is silent. Like the script it always exits 0: a hook never fails the session. The toolbelt dir
// is the script's own directory; the shim passes it (a binary cannot see the shim's location).
//
// Declared differences, each pinned by a test:
//
//   - The drift check runs in process, not through $here/verify-skill-drift.sh, so a stub of that script no
//     longer takes part (the Go test replaces the stubbing seam with the kit it runs on).
//   - The envelope is always JSON (as for kit-clean-hook): the script printed plain text when jq was missing.
//   - install --verify always runs under the bound. The script's pure-bash watchdog, the "no timeout binary,
//     no mktemp" skip and RESEARCH_SDD_NO_TIMEOUT_BIN (which also disabled the kit-staleness check) are gone:
//     they existed because bash has no timeout of its own. Its stdout and stderr are joined stdout first.
//   - A command that cannot be started reports "exited 126 with no typed line" (the shell's code, without the
//     shell's own message text).
//   - The kit-staleness git calls share one 3 s budget (each call gets what is left) instead of one `timeout 3`
//     around a shell function.
//   - Cutting a line to N characters counts runes, not bytes; the sanitised env value of an invalid timeout
//     or threshold keeps ASCII letters and digits only.

const (
	installVerifyMaxBytes = 4 << 20
	hookDriftDetailMore   = "  (+%d more - run research-sdd-install.sh --verify for the full list)"
	// hdrCannotRun heads the envelope of a hook whose own code panicked (kit issue #2610).
	hdrCannotRun = "ERROR: research-sdd skill-drift hook could not run (internal error):"
)

var (
	reVerifyFinding = regexp.MustCompile(`^verify (harness=[^ ]+ status=degraded|kit status=behind)`)
	reVerifyDrift   = regexp.MustCompile(`^verify harness=[^ ]+ status=drift `)
	reSDDigits      = regexp.MustCompile(`^[0-9]+$`)
)

// lookupEnv reads a variable and tells set-but-empty from unset, which cli.Stdio.Env cannot (TODO(#2387)).
func lookupEnv(s cli.Stdio, key string) (string, bool) {
	if s.Environ == nil {
		v := s.Env(key)
		return v, v != ""
	}
	prefix := key + "="
	for _, kv := range s.Environ() {
		if strings.HasPrefix(kv, prefix) {
			return kv[len(prefix):], true
		}
	}
	return "", false
}

// runeCut is `cut -c1-n`.
func runeCut(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		return string(r[:n])
	}
	return s
}

// sanitised is `printf %s "$v" | tr -cd '[:alnum:]._-' | cut -c1-30`.
func sanitised(v string) string {
	var b strings.Builder
	for _, c := range []byte(v) {
		if c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '.' || c == '_' || c == '-' {
			b.WriteByte(c)
		}
	}
	return runeCut(b.String(), 30)
}

// threshold is the bash validation of a numeric env value: 1 to 6 decimal digits, read base 10. ok=false is an
// invalid value (empty, non-digit or 7+ characters).
func threshold(v string) (n int, ok bool) {
	if v == "" || len(v) > 6 || !reSDDigits.MatchString(v) {
		return 0, false
	}
	n, _ = strconv.Atoi(v)
	return n, true
}

// withTail is `head${tail:+\ntail}`: head, then the tail on its own line when there is one.
func withTail(head, tail string) string {
	if tail == "" {
		return head
	}
	return head + "\n" + tail
}

// joinNL appends line to text with a newline between them when text is not empty (`${text:+$text\n}$line`).
func joinNL(text, line string) string {
	if text == "" {
		return line
	}
	return text + "\n" + line
}

func runSkillDriftHook(args []string, s cli.Stdio) int {
	return runSkillDriftHookWith(args, s, defaultHookBudgets())
}

// runSkillDriftHookWith is runSkillDriftHook with its time budgets given.
func runSkillDriftHookWith(args []string, s cli.Stdio, b hookBudgets) int {
	var buf bytes.Buffer // only a panic writes here: the body prints its own envelope
	if hookenv.Guard(&buf, func() int { return skillDriftHookBody(args, s, b) }) != cli.ExitOK {
		hookenv.WriteSessionStart(s.Out, hdrCannotRun+"\n"+strings.TrimRight(buf.String(), "\n"))
	}
	return cli.ExitOK // a hook never fails the session
}

// skillDriftHookBody is the hook proper; runSkillDriftHookWith guards it against a panic.
func skillDriftHookBody(args []string, s cli.Stdio, b hookBudgets) int {
	here := ""
	if len(args) > 0 {
		here = args[0]
	}
	if here == "" {
		root, ok := resolveSkillDriftKit("", s)
		if !ok {
			return cli.ExitOK // a hook never fails the session
		}
		here = filepath.Join(root, "toolbelt")
	}
	if !filepath.IsAbs(here) {
		here = filepath.Join(s.Cwd, here)
	}
	if p, ok := physicalDir(here); ok {
		here = p
	}

	// 1. the drift check of every harness, stdout and stderr joined
	var buf bytes.Buffer
	rc := skillDriftCheck(filepath.Dir(here), []string{"--all"}, s, &buf, &buf)
	out := strings.TrimRight(buf.String(), "\n")

	// 2. install --verify
	vcmd := s.Env("RESEARCH_SDD_INSTALL_VERIFY_CMD")
	if vcmd == "" {
		vcmd = filepath.Join(here, "..", "install", "research-sdd-install.sh")
	}
	extra, vrc := "", 0
	if executableOS(vcmd) {
		var vnote string
		extra, vrc, vnote = installVerify(vcmd, s, b)
		if vnote != "" {
			extra = joinNL(extra, vnote)
		}
	} else {
		extra = "verify: install --verify could not run (not executable: " + vcmd[strings.LastIndex(vcmd, "/")+1:] + ")"
	}

	// 3. kit staleness
	if s.Env("RESEARCH_SDD_KIT_STALE_CHECK") != "off" && vrc != 124 {
		extra = applyKitStale(extra, vrc, here, s, b)
	}

	if rc == 0 && extra == "" {
		return cli.ExitOK // all in sync or absent, nothing to flag: completely silent
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
		out = joinNL(out, extra)
	}
	hookenv.WriteSessionStart(s.Out, msg+"\n"+out)
	return cli.ExitOK
}

// installVerify runs `vcmd --verify` under the bound and returns the lines the hook surfaces (extra), the exit
// code the shell would have seen (124 timed out) and the invalid-timeout note.
func installVerify(vcmd string, s cli.Stdio, b hookBudgets) (extra string, vrc int, vnote string) {
	vt := b.verifyDefault
	if raw, set := lookupEnv(s, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"); set {
		if n, ok := threshold(raw); ok && n >= 1 {
			vt = n
		} else if raw == "" {
			vnote = "verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT (empty), using 10s"
		} else {
			vnote = "verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT='" + sanitised(raw) + "', using 10s"
		}
	}
	var environ []string
	if s.Environ != nil {
		environ = s.Environ()
	}
	res, err := proc.Run(proc.Spec{
		Argv: []string{vcmd, "--verify"}, Dir: s.Cwd, Env: environ,
		Timeout: b.verifyBound(vt), MaxBytes: installVerifyMaxBytes, Now: s.Clock,
	})
	vout := ""
	switch {
	case err != nil:
		vrc = 126
	case res.Reason == proc.ReasonTimeout:
		vrc = 124
	default:
		vrc = res.ReturnCode
		if vrc < 0 {
			vrc = 128 - vrc
		}
	}
	if err == nil {
		vout = strings.TrimRight(string(res.Stdout)+string(res.Stderr), "\n")
	}
	lines := strings.Split(vout, "\n")

	// Only findings: harness drift / degraded and kit behind (4 lines of 170 chars at most). match, absent and
	// current stay silent; a kit `degraded` (tarball, no upstream) cannot be cleared at session start.
	var found []string
	for _, l := range lines {
		if reVerifyFinding.MatchString(l) {
			found = append(found, runeCut(l, 170))
			if len(found) == 4 {
				break
			}
		}
	}
	extra = strings.Join(found, "\n")
	var drift []string
	for _, l := range lines {
		if reVerifyDrift.MatchString(l) {
			drift = append(drift, driftBlock(l)...)
		}
	}
	if len(drift) > 0 {
		extra = withTail(strings.Join(drift, "\n"), extra)
	}
	switch {
	case vrc == 124:
		extra = withTail("verify: install --verify timed out (RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, default 10s; on the pure-bash watchdog path the bound is that value plus up to ~0.5 s of sleep-probe time)", extra)
	case extra == "" && vrc != 0:
		extra = fmt.Sprintf("verify: install --verify exited %d with no typed line", vrc)
	}
	return extra, vrc, vnote
}

// driftBlock is the awk program of the hook: one drift line lists every drifted member on ONE line, and an
// annotated `(extra: ...)` entry carries the path to reconcile into. Per harness: the header, at most 3 entries
// of at most 280 chars (annotated entries first, so a regular-file TARGETS.md is never the one dropped), an
// explicit `(+N more ...)` line when entries were cut, then the kept hand-edit list on its own line.
func driftBlock(line string) []string {
	const entries, width, keptWidth = 3, 280, 160
	kept := ""
	if k := strings.Index(line, " kept-hand-edit="); k >= 0 {
		kept = line[k+len(" kept-hand-edit="):]
		line = line[:k]
	}
	d := strings.Index(line, " drifted=")
	if d < 0 {
		return []string{runeCut(line, width)}
	}
	block := []string{line[:d]}
	var e []string
	if rest := line[d+len(" drifted="):]; rest != "" {
		e = strings.Split(rest, ",")
	}
	shown := 0
	for pass := 1; pass <= 2; pass++ {
		for _, ent := range e {
			if (pass == 1) != strings.Contains(ent, "(extra: ") {
				continue
			}
			if shown < entries {
				block = append(block, "  - "+runeCut(ent, width))
				shown++
			}
		}
	}
	if len(e) > shown {
		block = append(block, fmt.Sprintf(hookDriftDetailMore, len(e)-shown))
	}
	if kept != "" {
		block = append(block, "  kept-hand-edit: "+runeCut(kept, keptWidth))
	}
	return block
}

// applyKitStale is the kit-staleness part of the hook (kit issue #2130): ONE typed `stale` line when the kit is
// behind its upstream by more than RESEARCH_SDD_KIT_STALE_MAX_COMMITS (default 20) or the last fetch is older
// than RESEARCH_SDD_KIT_STALE_MAX_DAYS (default 7). Own thresholds govern: install --verify's `kit status=behind`
// line is dropped when this check measured the kit, except a diverged one, which stays and replaces the stale
// line.
func applyKitStale(extra string, vrc int, here string, s cli.Stdio, b hookBudgets) string {
	st := kitStale(here, s, b)
	if st.state == "ok" || st.state == "stale" {
		keep, diverged := "", false
		for _, l := range strings.Split(extra, "\n") {
			switch {
			case strings.HasPrefix(l, "verify kit status=behind") && strings.Contains(strings.TrimPrefix(l, "verify kit status=behind"), "diverged"):
				diverged = true
				keep = joinNL(keep, l)
			case strings.HasPrefix(l, "verify kit status=behind"):
			default:
				keep = joinNL(keep, l)
			}
		}
		extra = keep
		if diverged {
			st.line = ""
		}
		// a non-zero install --verify exit must never be silenced by the dedupe
		if extra == "" && vrc != 0 {
			extra = fmt.Sprintf("verify: install --verify exited %d with no typed line", vrc)
		}
	}
	for _, l := range []string{st.note, st.line, st.deg} {
		if l != "" {
			extra = joinNL(extra, l)
		}
	}
	return extra
}

type staleResult struct {
	state, line, note, deg string
}

// kitStale is _rsdd_kit_stale. state is ok, stale or unknown; line is the stale line; note announces an
// invalid threshold; deg is the verbose-only typed degraded line.
func kitStale(here string, s cli.Stdio, b hookBudgets) staleResult {
	r := staleResult{state: "unknown"}
	kmax, kdays := 20, 7
	if raw, set := lookupEnv(s, "RESEARCH_SDD_KIT_STALE_MAX_COMMITS"); set {
		if n, ok := threshold(raw); ok {
			kmax = n
		} else {
			r.note = "verify kit-stale: invalid RESEARCH_SDD_KIT_STALE_MAX_COMMITS='" + sanitised(raw) + "', using 20"
		}
	}
	if raw, set := lookupEnv(s, "RESEARCH_SDD_KIT_STALE_MAX_DAYS"); set {
		if n, ok := threshold(raw); ok {
			kdays = n
		} else {
			r.note = joinNL(r.note, "verify kit-stale: invalid RESEARCH_SDD_KIT_STALE_MAX_DAYS='"+sanitised(raw)+"', using 7")
		}
	}
	kdir := s.Env("RESEARCH_SDD_KIT_DIR")
	if kdir == "" {
		kdir = filepath.Join(here, "..")
	}
	m := measureKit(kdir, kmax, kdays, s, b.kitStale)
	r.state, r.line = m.state, m.line
	if s.Env("RESEARCH_SDD_KIT_STALE_VERBOSE") != "" && m.deg != "" {
		r.deg = "verify kit-stale status=degraded reason=" + m.deg
	}
	return r
}

type kitMeasure struct{ state, line, deg string }

// measureKit is _rk_measure: the git work, under one shared budget.
func measureKit(kdir string, kmax, kdays int, s cli.Stdio, budget time.Duration) kitMeasure {
	m := kitMeasure{state: "unknown"}
	clock := s.Clock
	deadline := clock().Add(budget)
	expired := false
	run := func(dir string, args ...string) (string, error) {
		g := gitRunner(s)
		g.Timeout = deadline.Sub(clock())
		if g.Timeout < time.Millisecond {
			g.Timeout = time.Millisecond
		}
		out, err := g.Run(dir, args...)
		if errors.Is(err, git.ErrTimeout) {
			expired = true
		}
		return strings.TrimRight(string(out), "\n"), err
	}
	abandon := func() kitMeasure {
		return kitMeasure{state: "unknown", deg: "git did not answer within " + budget.String() + " (check abandoned)"}
	}

	top, err := run(kdir, "rev-parse", "--show-toplevel")
	if errors.Is(err, git.ErrMissing) {
		m.deg = "git not found; cannot tell whether the kit is behind its upstream"
		return m
	}
	if expired {
		return abandon()
	}
	if err != nil || top == "" {
		m.deg = "kit dir is not a git checkout (tarball install?)"
		return m
	}
	kd, kok := physicalDir(kdir)
	t, tok := physicalDir(top)
	if !kok || !tok || (t != kd && t != filepath.Dir(kd)) {
		m.deg = "kit dir sits inside an unrelated repo; its upstream is not the kit's"
		return m
	}
	ref, fallback := "", false
	if up, err := run(kd, "rev-parse", "--abbrev-ref", "@{upstream}"); err == nil && up != "" {
		ref = up
	} else if _, err := run(kd, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"); err == nil {
		ref, fallback = "origin/main", true
	}
	if expired {
		return abandon()
	}
	if ref == "" {
		m.deg = "no upstream ref (no @{upstream}, no origin/main); cannot tell whether the kit is behind"
		return m
	}
	n, err := run(kd, "rev-list", "--count", "HEAD.."+ref)
	if expired {
		return abandon()
	}
	if err != nil || !reSDDigits.MatchString(n) {
		m.deg = "could not count commits behind " + ref
		return m
	}
	fh, err := run(kd, "rev-parse", "--git-path", "FETCH_HEAD")
	if expired {
		return abandon()
	}
	if err != nil || fh == "" {
		m.deg = "could not locate FETCH_HEAD (git rev-parse --git-path failed)"
		return m
	}
	if !filepath.IsAbs(fh) {
		fh = kd + "/" + fh
	}
	age, haveAge := 0, false
	if isFileOS(fh) {
		if st, err := os.Stat(fh); err == nil {
			age, haveAge = int((clock().Unix()-st.ModTime().Unix())/86400), true
			if age < 0 {
				age = 0
			}
		}
	}
	switch {
	case haveAge:
	case !isFileOS(fh):
		m.deg = fmt.Sprintf("no FETCH_HEAD (never fetched): age criterion skipped, judged by commit count only (behind=%s of max %d)", n, kmax)
	default:
		m.deg = fmt.Sprintf("cannot read the age of the last fetch; judged by commit count only (behind=%s of max %d)", n, kmax)
	}
	m.state = "ok"
	behind, _ := strconv.Atoi(n)
	if behind > kmax || (haveAge && age > kdays) {
		m.state = "stale"
		disp := kd
		if home := s.Env("HOME"); strings.HasPrefix(kd, home+"/") {
			disp = "~" + strings.TrimPrefix(kd, home)
		}
		cmd := "git -C " + disp + " pull --ff-only" // no @{upstream}: pull would fail, hence the fallback form
		if fallback {
			cmd = "git -C " + disp + " fetch && git -C " + disp + " merge --ff-only " + ref
		}
		head := "verify kit-stale status=stale fix (no live session): " + cmd // the command comes first and is never cut
		ageText := "?"
		if haveAge {
			ageText = strconv.Itoa(age)
		}
		tail := fmt.Sprintf("; behind=%s (max %d) fetch_age=%sd (max %dd); local refs, may understate", n, kmax, ageText, kdays)
		room := 200 - len([]rune(head))
		if room < 0 {
			room = 0
		}
		m.line = head + runeCut(tail, room)
	}
	return m
}
