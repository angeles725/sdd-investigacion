package budget

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The pi / gentle-shell harness (kit issue #2174). What pi hands the model is not a SessionStart hook but
// system-prompt SECTIONS added by extensions on before_agent_start: the kit's research-sdd-hooks.ts plus every
// extension in <target>/.pi/extensions. lib/session-budget-pi.mjs (kept as JavaScript: it loads TypeScript
// extensions through node's type stripping) loads them under a fake `pi` and prints one authenticated record per
// line; this file runs it in the same sandbox as the Claude path and reduces the records.

func (m *meter) piDegraded(why string) {
	m.say("pi: DEGRADED — %s", why)
	m.say("state: degraded (%s; nothing was measured on pi)", why)
}

func (m *meter) pi() {
	m.say("verify-session-budget: %s", m.target)
	m.say("harness: pi (kit extension research-sdd-hooks.ts + <target>/.pi/extensions/*; sections added on before_agent_start after a startup session_start)")
	m.say("limits: fake pi (no-op API, no ctx.mode/model/tools); session_start handlers run in parallel, before_agent_start one after another; counted: sections, returned message content; unmeasured (typed): returned systemPrompt, event.systemPrompt edits")
	toolbelt := m.toolbeltDir()
	kitDir := m.s.Env("RSDD_BUDGET_KIT")
	if kitDir == "" && toolbelt != "" {
		kitDir = filepath.Dir(toolbelt)
	}
	ext := m.s.Env("RSDD_BUDGET_PI_HOOKS")
	if ext == "" {
		ext = kitDir + "/install/pi/research-sdd-hooks.ts"
	}
	helper := toolbelt + "/lib/session-budget-pi.mjs"
	if toolbelt == "" {
		helper = "lib/session-budget-pi.mjs (toolbelt directory unknown; run it through verify-session-budget.sh)"
	}
	m.say("kit: %s", kitDir)
	node, ok := m.lookPath("node")
	if !ok {
		m.piDegraded("node unavailable")
		return
	}
	ts := strings.TrimRight(string(m.env.run([]string{node, "-p", "String(process.features.typescript)"}, "", nil, false).stdout), "\n")
	switch ts {
	case "", "false", "undefined":
		ver := strings.TrimRight(string(m.env.run([]string{node, "--version"}, "", nil, false).stdout), "\n")
		m.piDegraded(fmt.Sprintf("node %s has no built-in TypeScript type stripping", ver))
		return
	}
	if !isRegular(ext) {
		m.piDegraded("kit extension not found: " + ext)
		return
	}
	if toolbelt == "" || !isRegular(helper) {
		m.piDegraded("measuring helper not found: " + helper)
		return
	}
	bwrap, ok := m.lookPath("bwrap")
	if !ok {
		m.piDegraded("no-sandbox: bwrap not installed")
		return
	}
	timeout, ok := m.lookPath("timeout")
	if !ok {
		m.piDegraded("no-sandbox: timeout not installed")
		return
	}
	if why, ok := m.probeBwrap(bwrap); !ok {
		m.piDegraded("no-sandbox: bwrap cannot start: " + why)
		return
	}
	pw, err := os.MkdirTemp(m.tmpRoot(), "tmp.")
	if err != nil {
		m.piDegraded("cannot create a temp dir")
		return
	}
	defer os.RemoveAll(pw)
	pihome, sbtmp, sbclaude := filepath.Join(pw, "pihome"), filepath.Join(pw, "tmp"), filepath.Join(pw, "dotclaude")
	for _, d := range []string{filepath.Join(pihome, "extensions"), sbtmp, sbclaude} {
		_ = os.MkdirAll(d, 0o755)
	}
	_ = os.Symlink(ext, filepath.Join(pihome, "extensions", "research-sdd-hooks.ts"))
	dotclaude := filepath.Join(m.target, ".claude")
	hasClaude := isDir(dotclaude)
	if hasClaude {
		if fail := m.copyClaude(dotclaude, sbclaude); fail != "" {
			m.piDegraded("incomplete-sandbox-copy: " + fail)
			return
		}
	}
	exts := append([]string{filepath.Join(pihome, "extensions", "research-sdd-hooks.ts")}, piExtensions(filepath.Join(m.target, ".pi", "extensions"))...)

	// Every wait is per handler; the run-wide cap covers the parallel session_start phase plus one wait per
	// extension after it, so one slow extension yields its own E record instead of a run-wide timeout.
	pcap := (m.toCap+5)*(len(exts)+1) + 10
	bargs := []string{"bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", sbtmp, sbtmp}
	if hasClaude {
		bargs = append(bargs, "--bind", sbclaude, dotclaude)
	} else {
		// No .claude to bind a throwaway copy over (bwrap cannot create a mount point on the read-only root):
		// shadow the target with a directory of symlinks into a read-only bind of the real one, plus a fresh
		// writable .claude, so the kit extension's session-sha write lands in the sandbox.
		sbroot, sborig := filepath.Join(pw, "root"), filepath.Join(pw, "orig")
		_ = os.MkdirAll(filepath.Join(sbroot, ".claude"), 0o755)
		_ = os.MkdirAll(sborig, 0o755)
		for _, n := range targetEntries(m.target) {
			_ = os.Symlink(filepath.Join(sborig, n), filepath.Join(sbroot, n))
		}
		bargs = append(bargs, "--ro-bind", m.target, sborig, "--bind", sbroot, m.target)
	}
	ms := strconv.Itoa(m.toCap * 1000)
	bargs = append(bargs,
		"--setenv", "TMPDIR", sbtmp, "--setenv", "HOME", sbtmp, "--setenv", "CLAUDE_PROJECT_DIR", m.target,
		"--setenv", "GENTLE_PI_AGENT_HOME", pihome, "--setenv", "RESEARCH_SDD_KIT", kitDir,
		"--setenv", "RSDD_PI_SWEEP_TIMEOUT_MS", ms, "--setenv", "RSDD_PI_SWEEP_WAIT_MS", strconv.Itoa(m.toCap*1000+2000),
		"--setenv", "RSDD_BUDGET_PI_WAIT_MS", strconv.Itoa(m.toCap*1000+5000),
		"--unsetenv", "GENTLE_PI_AGENTS_CHILD", "--unsetenv", "PI_CODING_AGENT_DIR", "--unsetenv", "RSDD_PI_HOOKS",
		"--unsetenv", "SSH_AUTH_SOCK", "--unsetenv", "SSH_AGENT_PID", "--unsetenv", "GPG_AGENT_INFO",
		"--unsetenv", "DBUS_SESSION_BUS_ADDRESS", "--unsetenv", "XDG_RUNTIME_DIR",
		"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent", "--chdir", m.target)

	// Records are authenticated: a per-run nonce goes to the helper on STDIN (extensions in its process can read
	// argv and env, not an already-consumed stdin) and prefixes every record. Anything else on stdout is forged by
	// an extension and is never evaluated.
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		m.piDegraded("no random nonce available")
		return
	}
	nonce := hex.EncodeToString(raw)
	recsFile, err := os.Create(filepath.Join(pw, "recs"))
	if err != nil {
		m.piDegraded("cannot create a temp dir")
		return
	}
	argv := append([]string{timeout, "-k", "2", strconv.Itoa(pcap)}, bargs...)
	argv = append(argv, "node", helper, m.target)
	argv = append(argv, exts...)
	r := m.env.run(argv, nonce+"\n", recsFile, false)
	_ = recsFile.Close()
	if r.rc == 124 || r.rc == 137 {
		m.piDegraded(fmt.Sprintf("timeout %ds: the extensions did not finish", pcap))
		return
	}
	if r.rc != 0 {
		m.piDegraded(fmt.Sprintf("extension harness exit %d (%s)", r.rc, cut120(firstLine(r.stderr))))
		return
	}
	recs, _ := os.ReadFile(filepath.Join(pw, "recs"))
	if len(recs) == 0 {
		m.piDegraded("extension harness produced no records (a silent 0 is not a measurement)")
		return
	}
	m.reducePi(string(recs), nonce, len(exts))
}

// reducePi turns the helper's records into report lines, state and aggregate.
func (m *meter) reducePi(recs, nonce string, nexts int) {
	nsec, total, ndeg, nrec, nfinal, forged := 0, 0, 0, 0, 0, 0
	zn := ""
	lines := strings.Split(recs, "\n")
	lines = lines[:len(lines)-1] // `read` never yields an unterminated last line
	for _, line := range lines {
		f := readTabs(line, 6)
		nn, kind, a, b, c, d := f[0], f[1], f[2], f[3], f[4], f[5]
		if nn != nonce {
			forged++
			continue
		}
		num := "0"
		switch kind {
		case "S":
			num = c
		case "T":
			num = b
		case "Z":
			num = a
		}
		n, ok := atoiOr(num)
		if !allDigits(num) || !ok {
			forged++ // numeric fields reach arithmetic only after this check
			continue
		}
		switch kind {
		case "S":
			nrec++
			nsec++
			st := "ok"
			switch d {
			case "pending":
				st = "degraded(sweeps pending)"
				ndeg++
			case "degraded-text":
				st = "degraded(section text reports DEGRADED)"
				ndeg++
			}
			m.say("section[%s] %s chars=%s status=%s", a, b, c, st)
			total += n
		case "U":
			nrec++
			ndeg++
			m.say("ext[%s] status=unmeasured(%s)", a, b)
		case "E":
			nrec++
			nfinal++
			ndeg++
			m.say("ext[%s] status=degraded(%s)", a, b)
		case "Z":
			zn = a
		case "T":
			nrec++
			nfinal++
			if b == "0" {
				if a == "research-sdd-hooks.ts" {
					ndeg++
					m.say("ext[%s] status=degraded(added no section: inactive?)", a)
				} else {
					m.say("ext[%s] added no section", a)
				}
			}
		}
	}
	// The helper ends with `Z <n>` and gives every extension exactly one T or E; anything else means it ended
	// early (an extension called process.exit, say) and the sections above are only part of the picture.
	if zn != strconv.Itoa(nexts) || nfinal != nexts {
		ndeg++
		nrec++
		marker := "missing"
		if zn != "" {
			marker = "present"
		}
		m.say("harness: degraded(incomplete record set: %d of %d extensions finished, closing marker %s)", nfinal, nexts, marker)
	}
	if forged != 0 {
		ndeg++
		nrec++
		m.say("harness: degraded(%d unauthenticated or malformed record line(s) ignored: an extension wrote to the helper's stdout)", forged)
	}
	partial := ""
	if ndeg > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded)", ndeg)
	}
	m.say("aggregate[pi]: %d chars (budget < %d) %s%s", total, sessionCap, verdict(total), partial)
	if ndeg > 0 {
		m.say("state: degraded (%d of %d pi records could not be fully measured)", ndeg, nrec)
	} else {
		m.say("state: ok (%d pi sections from %d extensions)", nsec, nexts)
	}
}

// readTabs is `IFS=$'\t' read -r v1 ... vn`: tab is IFS whitespace, so runs of tabs are one separator and the
// last variable takes the rest of the line with trailing tabs trimmed.
func readTabs(line string, n int) []string {
	out := make([]string, n)
	s := strings.TrimLeft(line, "\t")
	for i := 0; i < n-1 && s != ""; i++ {
		j := strings.IndexByte(s, '\t')
		if j < 0 {
			out[i], s = s, ""
			break
		}
		out[i], s = s[:j], strings.TrimLeft(s[j:], "\t")
	}
	if s != "" {
		out[n-1] = strings.TrimRight(s, "\t")
	}
	return out
}

// piExtensions lists the extensions below <target>/.pi/extensions the way the script's find did: regular files
// *.ts, *.js, *.mjs directly inside, and index.ts|js|mjs one directory down (symlinks are not followed, a
// symlinked extensions directory yields nothing), sorted bytewise by full path.
func piExtensions(dir string) []string {
	if fi, err := os.Lstat(dir); err != nil || !fi.IsDir() {
		return nil
	}
	var out []string
	des, _ := os.ReadDir(dir)
	for _, de := range des {
		p := filepath.Join(dir, de.Name())
		switch {
		case de.Type().IsRegular():
			if hasExt(de.Name(), ".ts", ".js", ".mjs") {
				out = append(out, p)
			}
		case de.IsDir():
			subs, _ := os.ReadDir(p)
			for _, sub := range subs {
				if sub.Type().IsRegular() && (sub.Name() == "index.ts" || sub.Name() == "index.js" || sub.Name() == "index.mjs") {
					out = append(out, filepath.Join(p, sub.Name()))
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func hasExt(name string, exts ...string) bool {
	for _, e := range exts {
		if strings.HasSuffix(name, e) {
			return true
		}
	}
	return false
}

// targetEntries are the names `"$t"/* "$t"/.[!.]*` expands to (existing or dangling symlinks).
func targetEntries(dir string) []string {
	des, _ := os.ReadDir(dir)
	var plain, dots []string
	for _, de := range des {
		n := de.Name()
		switch {
		case !strings.HasPrefix(n, "."):
			plain = append(plain, n)
		case len(n) > 1 && n[1] != '.':
			dots = append(dots, n)
		}
	}
	sort.Strings(plain)
	sort.Strings(dots)
	return append(plain, dots...)
}

func isRegular(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
