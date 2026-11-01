package budget

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// The Claude harness report: per session source, the hooks that source runs, then the WORST source (the one the budget
// verdict is about) and the typed state. Within a source identical commands are deduplicated and each distinct hook runs once.
// Typed states, never a silent zero: absent-input (no settings), empty-input (no SessionStart command hook for any source),
// degraded (jq missing, unreadable settings, unusable sandbox or locale, a hook that failed/timed out/was unresolvable),
// ok. Everything is WARN-only: the exit code is 0 for findings.

// report writes the report lines of one run.
type report struct{ w io.Writer }

func (r report) say(format string, a ...any) { fmt.Fprintf(r.w, format+"\n", a...) }

// claudeReport is the default (Claude) harness.
func claudeReport(e env, target string, toCap string, w io.Writer) {
	r := report{w}
	r.say("verify-session-budget: %s", target)
	settings := filepath.Join(target, ".claude", "settings.json")
	if !isRegular(settings) {
		r.say("state: absent-input (no %s)", settings)
		return
	}
	jq := e.lookPath("jq")
	if jq == "" {
		r.say("state: degraded (jq unavailable; no hook was run)")
		return
	}
	if !e.isJSONObject(jq, settings) {
		r.say("state: degraded (settings.json is not a readable JSON object; no hook was run)")
		return
	}
	tmp := e.get("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	work, err := os.MkdirTemp(tmp, "tmp.")
	if err != nil {
		r.say("state: degraded (cannot create a temp dir)")
		return
	}
	defer os.RemoveAll(work)

	recs := map[string][]hookRec{}
	anyRec := false
	for _, src := range sessionSources {
		rs, fail, ok := e.selectHooks(jq, settings, src)
		if !ok {
			r.say("state: degraded (cannot select SessionStart hooks for source %s: %s); no hook was run", src, fail)
			return
		}
		recs[src] = rs
		anyRec = anyRec || len(rs) > 0
	}
	if !anyRec {
		r.say("state: empty-input (no SessionStart command hook matches startup, resume, clear, compact or fork in %s)", settings)
		return
	}

	p := &probe{e: e, target: target, toCap: toCap, work: work, jq: jq, timeout: e.lookPath("timeout"),
		reason: e.sandboxReason(), utf8OK: e.utf8Counts(),
		sbClaude: filepath.Join(work, "dotclaude"), sbTmp: filepath.Join(work, "tmp"), outFile: filepath.Join(work, "out")}

	worstTotal, worstSrc := -1, ""
	var nDegAll, nTimedOut, nHooks, nTrunc int
	var degSrcs []string
	for _, src := range sessionSources {
		if len(recs[src]) == 0 {
			r.say("source %s: (no matching SessionStart hooks)", src)
			continue
		}
		r.say("source %s:", src)
		p.prepSandbox()
		n, total, nDeg := 0, 0, 0
		seen := map[string]bool{}
		for _, rec := range recs[src] {
			if seen[rec.cmd] {
				continue
			}
			seen[rec.cmd] = true
			n++
			nHooks++
			h := p.run(src, rec.cmd, rec.decl)
			shown := strings.ReplaceAll(rec.cmd, "\n", " \\n ")
			if h.kind == kindDegraded {
				r.say("hook[%d] chars=n/a status=%s cmd=%s", n, h.status, shown)
				nDeg++
				continue
			}
			r.say("hook[%d] chars=%d status=%s cmd=%s", n, h.chars, h.status, shown)
			total += h.chars
			switch h.kind {
			case kindTruncated:
				nTrunc++
			case kindTimedOut:
				nTimedOut++
			}
		}
		partial := ""
		if nDeg > 0 {
			partial = fmt.Sprintf(" (partial: %d degraded)", nDeg)
		}
		r.say("aggregate[%s]: %d chars (budget < %d) %s%s", src, total, budget, verdict(total), partial)
		nDegAll += nDeg
		if nDeg > 0 {
			degSrcs = append(degSrcs, src)
		}
		if total > worstTotal {
			worstTotal, worstSrc = total, src
		}
	}
	partial := ""
	if nDegAll > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded in %s)", nDegAll, strings.Join(degSrcs, ","))
	}
	r.say("aggregate: %d chars (budget < %d) %s%s worst-source=%s", worstTotal, budget, verdict(worstTotal), partial, worstSrc)
	if nDegAll > 0 {
		r.say("state: degraded (%d of %d hook runs could not be measured; %d timed-out)", nDegAll, nHooks, nTimedOut)
	} else {
		r.say("state: ok (%d hook runs, %d truncated, %d timed-out)", nHooks, nTrunc, nTimedOut)
	}
}
