package gate

import (
	"fmt"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"unicode/utf8"
)

// The Stop-branch log (kit issue #1258): every Stop appends ONE line (UTC timestamp, target, session, branch taken,
// seeding evidence) to $TARGET/.claude/.rsdd-retro-gate-stops.log, the state directory the gate already owns. It is
// written when the command ends, on every exit path after the target resolved (a helper-load failure is logged as
// branch=error-helper), and never changes the verdict or the exit code. Bounded: past rgStopLogMax lines the file
// is cut to its last rgStopLogKeep through a per-process temp name. A failed write is a typed stderr WARN.

// rotateSeq makes the temp name of a rotation unique per call, so concurrent Stops, even of one process, never share one.
var rotateSeq atomic.Uint64

// writeStopLog is _stop_log_write. The caller holds g.mu.
func (g *retroGate) writeStopLog() {
	mode := ""
	if g.degraded {
		mode = " mode=degraded"
	}
	d := g.target + "/.claude"
	f := d + "/.rsdd-retro-gate-stops.log"
	branch := g.branch
	if branch == "" {
		branch = "unclassified"
	}
	line := fmt.Sprintf("%s target=%s session=%s branch=%s%s", g.s.Clock().UTC().Format("2006-01-02T15:04:05Z"),
		path0Base(g.target), sidSafe(g.sessionID, envUTF8(g.s.Env)), branch, mode)
	if g.seed != "" {
		line += " seeding=" + g.seed
	}
	line = strings.ReplaceAll(line, "\n", " ")
	if appendLine(d, f, line) != nil {
		g.errf("retro-gate: WARN: stop-log write failed (%s) — Stop not recorded; verdict unaffected\n", f)
		return
	}
	b, err := os.ReadFile(f)
	if err != nil || strings.Count(string(b), "\n") <= rgStopLogMax {
		return
	}
	tmp := fmt.Sprintf("%s.tmp.%d.%d", f, os.Getpid(), rotateSeq.Add(1))
	if os.WriteFile(tmp, tailLines(b, rgStopLogKeep), 0o666) == nil && os.Rename(tmp, f) == nil {
		return
	}
	_ = os.Remove(tmp)
	g.errf("retro-gate: WARN: stop-log rotation failed (%s) — log may grow; verdict unaffected\n", f)
}

// appendLine is `mkdir -p dir && printf '%s\n' line >> file`.
func appendLine(dir, file, line string) error {
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return err
	}
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(line + "\n"); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// tailLines is `tail -n n`: the last n lines, a final line without its newline counting as one.
func tailLines(b []byte, n int) []byte {
	end := len(b)
	if end > 0 && b[end-1] == '\n' {
		end--
	}
	seen := 0
	for i := end - 1; i >= 0; i-- {
		if b[i] == '\n' {
			seen++
			if seen == n {
				return b[i+1:]
			}
		}
	}
	return b
}

// envUTF8 reports whether the locale of env is UTF-8 (LC_ALL, then LC_CTYPE, then LANG).
func envUTF8(env func(string) string) bool {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v := env(k); v != "" {
			v = strings.ToLower(v)
			return strings.Contains(v, "utf-8") || strings.Contains(v, "utf8")
		}
	}
	return false
}

// startSignalWatch installs the SIGTERM/SIGINT handling of the bash traps: the stop-log line is tagged
// branch=killed and the process ends with 143 / 130. The returned func removes the handler.
func startSignalWatch(g *retroGate) func() {
	ch := make(chan os.Signal, 2)
	done := make(chan struct{})
	signal.Notify(ch, syscall.SIGTERM, os.Interrupt)
	go func() {
		select {
		case sig := <-ch:
			if sig == os.Interrupt {
				g.kill(130)
			} else {
				g.kill(143)
			}
		case <-done:
		}
	}()
	return func() {
		signal.Stop(ch)
		close(done)
	}
}

// ── JSON output ──────────────────────────────────────────────────────────────

// escapeReason is _json_escape_reason, byte for byte: the decision channel must not depend on jq. Backslash,
// quote and newline get their short forms, tab and CR too, every other C0 control (RFC 8259) becomes \u00XX, and
// every other byte, valid UTF-8 or not, passes through.
func escapeReason(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '"':
			b.WriteString(`\"`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '\r':
			b.WriteString(`\r`)
		case c < 0x20:
			fmt.Fprintf(&b, `\u%04x`, c)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// rgJQString renders s the way jq prints a string: invalid UTF-8 bytes become U+FFFD one by one, the short escapes
// for quote, backslash and \b \f \n \r \t, \u00xx for every other C0 control and for DEL.
func rgJQString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			b.WriteString("�")
			i++
			continue
		}
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			b.WriteString(s[i : i+size])
		}
		i += size
	}
	b.WriteByte('"')
	return b.String()
}

// jqNullable is the filter `def nn: if . == "" then null else . end`.
func jqNullable(s string) string {
	if s == "" {
		return "null"
	}
	return rgJQString(s)
}

// verdictAllow is _verdict_allow: the --json counterpart of a bare allow, a no-op in the default mode.
func (g *retroGate) verdictAllow(mode, retro, reason string) {
	if g.jsonMode {
		g.emitEnvelope("allow", mode, retro, reason)
	}
}

// emitEnvelope prints the ONE research-sdd.retro-gate/v1 document (contract: json-envelope.v1.md) in jq's default
// two-space layout. The state is always `ok` on a completed run; the block reason is the only nullable text that
// is carried verbatim.
func (g *retroGate) emitEnvelope(verdict, mode, retro, reason string) {
	blocked, degraded := 0, 0
	reasonJSON := "null"
	if verdict == "block" {
		blocked = 1
		reasonJSON = rgJQString(reason)
	}
	if mode == "mtime-fallback" {
		degraded = 1
	}
	branch := g.branch
	if branch == "" {
		branch = "unclassified"
	}
	var b strings.Builder
	b.WriteString("{\n")
	b.WriteString("  \"schema\": \"research-sdd.retro-gate/v1\",\n")
	b.WriteString("  \"state\": \"ok\",\n")
	b.WriteString("  \"reason\": null,\n")
	b.WriteString("  \"counts\": {\n")
	fmt.Fprintf(&b, "    \"blocked\": %d,\n    \"degraded_check\": %d,\n    \"unverified\": %d\n  },\n", blocked, degraded, g.unverif)
	b.WriteString("  \"items\": [\n    {\n")
	b.WriteString("      \"kind\": \"verdict\",\n")
	fmt.Fprintf(&b, "      \"verdict\": %s,\n", rgJQString(verdict))
	fmt.Fprintf(&b, "      \"branch\": %s,\n", rgJQString(branch))
	fmt.Fprintf(&b, "      \"target\": %s,\n", rgJQString(baseName(g.target)))
	fmt.Fprintf(&b, "      \"session_id\": %s,\n", jqNullable(g.sessionID))
	fmt.Fprintf(&b, "      \"check_mode\": %s,\n", jqNullable(mode))
	fmt.Fprintf(&b, "      \"newest_retro\": %s,\n", jqNullable(retro))
	fmt.Fprintf(&b, "      \"reason\": %s\n", reasonJSON)
	b.WriteString("    }\n  ]\n}\n")
	fmt.Fprint(g.s.Out, b.String())
}
