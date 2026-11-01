package budget

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The pi / gentle-shell harness (kit issue #2174). What pi hands the model is not a SessionStart hook but system-prompt SECTIONS
// added by extensions on before_agent_start: the kit's research-sdd-hooks.ts plus every extension in <target>/.pi/extensions.
// lib/session-budget-pi.mjs (Node, unchanged) loads them under a fake `pi` inside the same bubblewrap sandbox and prints one
// authenticated record per line; this file runs it and turns the records into the report. A pi path that cannot run prints
// `pi: DEGRADED - <reason>` and no aggregate[pi] (never a zero).

// bashArith reads a string the way `$(( ))` does for a plain number: a leading 0 means octal. A value that is not a number in
// that base keeps its decimal reading (bash would abort the expression; digits-only input never reaches here otherwise).
func bashArith(s string) int {
	if len(s) > 1 && s[0] == '0' {
		if n, err := strconv.ParseInt(s, 8, 64); err == nil {
			return int(n)
		}
	}
	n, _ := strconv.Atoi(s)
	return n
}

// splitTabFields is `IFS=$'\t' read -r a b c d e f`: tab is an IFS WHITESPACE character, so runs of tabs collapse into one
// separator (an empty field shifts the rest), leading tabs are skipped, and the last variable takes the remainder with its
// trailing tabs removed.
func splitTabFields(line string, n int) []string {
	f := make([]string, n)
	s := strings.TrimLeft(line, "\t")
	for i := 0; i < n-1; i++ {
		if s == "" {
			return f
		}
		if j := strings.IndexByte(s, '\t'); j >= 0 {
			f[i] = s[:j]
			s = strings.TrimLeft(s[j:], "\t")
		} else {
			f[i], s = s, ""
		}
	}
	f[n-1] = strings.TrimRight(s, "\t")
	return f
}

// lnS is `ln -s src link`: an existing directory at link receives the symlink under src's base name.
func lnS(src, link string) {
	if fi, err := os.Stat(link); err == nil && fi.IsDir() {
		link = filepath.Join(link, filepath.Base(src))
	}
	_ = os.Symlink(src, link)
}

// piExtensions lists the target's own extensions: <dir>/*.ts|*.js|*.mjs and <dir>/<sub>/index.ts|js|mjs (regular files only,
// symlinks not followed), sorted bytewise as `LC_ALL=C sort` does.
func piExtensions(dir string) []string {
	var out []string
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	isExt := func(n string) bool {
		return strings.HasSuffix(n, ".ts") || strings.HasSuffix(n, ".js") || strings.HasSuffix(n, ".mjs")
	}
	for _, en := range ents {
		p := filepath.Join(dir, en.Name())
		switch {
		case en.Type().IsRegular() && isExt(en.Name()):
			out = append(out, p)
		case en.IsDir() && en.Type()&os.ModeSymlink == 0:
			subs, _ := os.ReadDir(p)
			for _, s := range subs {
				if s.Type().IsRegular() && (s.Name() == "index.ts" || s.Name() == "index.js" || s.Name() == "index.mjs") {
					out = append(out, filepath.Join(p, s.Name()))
				}
			}
		}
	}
	sort.Strings(out)
	return out
}

func piDegraded(r report, why string) {
	r.say("pi: DEGRADED — %s", why)
	r.say("state: degraded (%s; nothing was measured on pi)", why)
}

// piReport is the pi harness. self is the toolbelt directory (it holds lib/session-budget-pi.mjs).
func piReport(e env, target, toCap, self string, w io.Writer) {
	r := report{w}
	r.say("verify-session-budget: %s", target)
	r.say("harness: pi (kit extension research-sdd-hooks.ts + <target>/.pi/extensions/*; sections added on before_agent_start after a startup session_start)")
	r.say("limits: fake pi (no-op API, no ctx.mode/model/tools); session_start handlers run in parallel, before_agent_start one after another; counted: sections, returned message content; unmeasured (typed): returned systemPrompt, event.systemPrompt edits")
	kit := e.get("RSDD_BUDGET_KIT")
	if kit == "" {
		kit = self
		if i := strings.LastIndexByte(kit, '/'); i >= 0 {
			kit = kit[:i]
		} // ${self%/*}
	}
	ext := e.get("RSDD_BUDGET_PI_HOOKS")
	if ext == "" {
		ext = kit + "/install/pi/research-sdd-hooks.ts"
	}
	helper := self + "/lib/session-budget-pi.mjs"
	r.say("kit: %s", kit)
	node := e.lookPath("node")
	if node == "" {
		piDegraded(r, "node unavailable")
		return
	}
	tsOut, _ := e.cmd(node, "-p", "String(process.features.typescript)").Output()
	switch strings.TrimRight(string(tsOut), "\n") {
	case "", "false", "undefined":
		ver, _ := e.cmd(node, "--version").Output()
		piDegraded(r, fmt.Sprintf("node %s has no built-in TypeScript type stripping", strings.TrimRight(string(ver), "\n")))
		return
	}
	if !isRegular(ext) {
		piDegraded(r, "kit extension not found: "+ext)
		return
	}
	if !isRegular(helper) {
		piDegraded(r, "measuring helper not found: "+helper)
		return
	}
	if reason := e.sandboxReason(); reason != "" {
		piDegraded(r, "no-sandbox: "+reason)
		return
	}
	tmp := e.get("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	pw, err := os.MkdirTemp(tmp, "tmp.")
	if err != nil {
		piDegraded(r, "cannot create a temp dir")
		return
	}
	defer os.RemoveAll(pw)
	pihome, sbtmp, sbclaude := filepath.Join(pw, "pihome"), filepath.Join(pw, "tmp"), filepath.Join(pw, "dotclaude")
	for _, d := range []string{filepath.Join(pihome, "extensions"), sbtmp, sbclaude} {
		_ = os.MkdirAll(d, 0o755)
	}
	lnS(ext, filepath.Join(pihome, "extensions", "research-sdd-hooks.ts"))
	hasClaude := isDir(filepath.Join(target, ".claude"))
	if hasClaude {
		if fail := e.copyClaude(target, sbclaude); fail != "" {
			piDegraded(r, "incomplete-sandbox-copy: "+fail)
			return
		}
	}
	exts := []string{filepath.Join(pihome, "extensions", "research-sdd-hooks.ts")}
	if isDir(filepath.Join(target, ".pi", "extensions")) {
		exts = append(exts, piExtensions(filepath.Join(target, ".pi", "extensions"))...)
	}
	// Every wait is per handler; the run-wide cap covers the parallel session_start phase plus one wait per extension after
	// it, so one slow extension yields its own E record instead of a run-wide timeout.
	capN := bashArith(toCap)
	pcap := (capN+5)*(len(exts)+1) + 10
	bargs := []string{"bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--bind", sbtmp, sbtmp}
	if hasClaude {
		bargs = append(bargs, "--bind", sbclaude, filepath.Join(target, ".claude"))
	} else {
		// No .claude to bind a throwaway copy over (bwrap cannot create a mount point on the read-only root): shadow the target
		// with a directory of symlinks into a read-only bind of the real one, plus a fresh writable .claude, so the kit
		// extension's session-sha write lands in the sandbox exactly as it does when a copy is bound.
		sbroot, sborig := filepath.Join(pw, "root"), filepath.Join(pw, "orig")
		_ = os.MkdirAll(filepath.Join(sbroot, ".claude"), 0o755)
		_ = os.MkdirAll(sborig, 0o755)
		for _, p := range targetEntries(target) {
			lnS(filepath.Join(sborig, filepath.Base(p)), filepath.Join(sbroot, filepath.Base(p)))
		}
		bargs = append(bargs, "--ro-bind", target, sborig, "--bind", sbroot, target)
	}
	bargs = append(bargs, "--setenv", "TMPDIR", sbtmp, "--setenv", "HOME", sbtmp, "--setenv", "CLAUDE_PROJECT_DIR", target,
		"--setenv", "GENTLE_PI_AGENT_HOME", pihome, "--setenv", "RESEARCH_SDD_KIT", kit,
		"--setenv", "RSDD_PI_SWEEP_TIMEOUT_MS", strconv.Itoa(capN*1000),
		"--setenv", "RSDD_PI_SWEEP_WAIT_MS", strconv.Itoa(capN*1000+2000),
		"--setenv", "RSDD_BUDGET_PI_WAIT_MS", strconv.Itoa(capN*1000+5000),
		"--unsetenv", "GENTLE_PI_AGENTS_CHILD", "--unsetenv", "PI_CODING_AGENT_DIR", "--unsetenv", "RSDD_PI_HOOKS")
	for _, v := range unsetVars {
		bargs = append(bargs, "--unsetenv", v)
	}
	bargs = append(bargs, namespaceFlags...)
	bargs = append(bargs, "--chdir", target)

	// Records are authenticated: a per-run nonce goes to the helper on STDIN (extensions in its process can read argv and env,
	// not an already-consumed stdin) and prefixes every record. Anything else on stdout is forged by an extension and is never
	// evaluated.
	nb := make([]byte, 16)
	if _, err := rand.Read(nb); err != nil {
		piDegraded(r, "no random nonce available")
		return
	}
	nonce := hex.EncodeToString(nb)
	recsPath, errPath := filepath.Join(pw, "recs"), filepath.Join(pw, "err")
	recsF, _ := os.Create(recsPath)
	errF, _ := os.Create(errPath)
	argv := append([]string{"-k", "2", strconv.Itoa(pcap)}, bargs...)
	argv = append(argv, "node", helper, target)
	argv = append(argv, exts...)
	c := e.cmd(e.lookPath("timeout"), argv...)
	c.Stdin, c.Stdout, c.Stderr = strings.NewReader(nonce+"\n"), recsF, errF
	rc := exitCode(c.Run())
	_ = recsF.Close()
	_ = errF.Close()
	switch {
	case rc == 124 || rc == 137:
		piDegraded(r, fmt.Sprintf("timeout %ds: the extensions did not finish", pcap))
		return
	case rc != 0:
		eb, _ := os.ReadFile(errPath)
		piDegraded(r, fmt.Sprintf("extension harness exit %d (%s)", rc, firstLine(string(eb))))
		return
	}
	recs, _ := os.ReadFile(recsPath)
	if len(recs) == 0 {
		piDegraded(r, "extension harness produced no records (a silent 0 is not a measurement)")
		return
	}
	summarisePi(r, string(recs), nonce, exts)
}

// targetEntries are the target's `"$t"/*` and `"$t"/.[!.]*` entries that exist (or are symlinks, even broken ones).
func targetEntries(target string) []string {
	ents, err := os.ReadDir(target)
	if err != nil {
		return nil
	}
	var plain, dots []string
	for _, en := range ents {
		n := en.Name()
		switch {
		case !strings.HasPrefix(n, "."):
			plain = append(plain, filepath.Join(target, n))
		case len(n) >= 2 && n[1] != '.':
			dots = append(dots, filepath.Join(target, n))
		}
	}
	sort.Strings(plain)
	sort.Strings(dots)
	return append(plain, dots...)
}

// summarisePi turns the helper's records into the report lines. A record is trusted only with the run's nonce and numeric
// numeric fields; a line that fails either is counted as forged and ignored, never evaluated.
func summarisePi(r report, recs, nonce string, exts []string) {
	var nsec, total, ndeg, nrec, nfinal, forged int
	zn := ""
	text := recs
	for {
		i := strings.IndexByte(text, '\n')
		if i < 0 { // an unterminated last line is never processed (bash `read` fails on it)
			break
		}
		line := strings.ReplaceAll(text[:i], "\x00", "")
		text = text[i+1:]
		f := splitTabFields(line, 6)
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
		if !onlyDigits(num) {
			forged++
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
			r.say("section[%s] %s chars=%s status=%s", a, b, c, st)
			n, _ := strconv.Atoi(c)
			total += n
		case "U":
			nrec++
			ndeg++
			r.say("ext[%s] status=unmeasured(%s)", a, b)
		case "E":
			nrec++
			nfinal++
			ndeg++
			r.say("ext[%s] status=degraded(%s)", a, b)
		case "Z":
			zn = a
		case "T":
			nrec++
			nfinal++
			if b == "0" {
				if a == "research-sdd-hooks.ts" {
					ndeg++
					r.say("ext[%s] status=degraded(added no section: inactive?)", a)
				} else {
					r.say("ext[%s] added no section", a)
				}
			}
		}
	}
	// The helper ends with `Z <n>` and gives every extension exactly one T or E; anything else means it ended early (an
	// extension called process.exit, say) and the sections above are only part of the picture.
	if zn != strconv.Itoa(len(exts)) || nfinal != len(exts) {
		ndeg++
		nrec++
		marker := "missing"
		if zn != "" {
			marker = "present"
		}
		r.say("harness: degraded(incomplete record set: %d of %d extensions finished, closing marker %s)", nfinal, len(exts), marker)
	}
	if forged != 0 {
		ndeg++
		nrec++
		r.say("harness: degraded(%d unauthenticated or malformed record line(s) ignored: an extension wrote to the helper's stdout)", forged)
	}
	partial := ""
	if ndeg > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded)", ndeg)
	}
	r.say("aggregate[pi]: %d chars (budget < %d) %s%s", total, budget, verdict(total), partial)
	if ndeg > 0 {
		r.say("state: degraded (%d of %d pi records could not be fully measured)", ndeg, nrec)
	} else {
		r.say("state: ok (%d pi sections from %d extensions)", nsec, len(exts))
	}
}
