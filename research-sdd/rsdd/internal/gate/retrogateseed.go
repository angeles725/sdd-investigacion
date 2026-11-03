package gate

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// ghProbeTimeout bounds `gh auth status`; the bash had no bound, a probe that never ends is the only thing it changes.
const ghProbeTimeout = 2 * time.Minute

// bashRun runs `bash script args...` with the process environment and returns its status (127 when bash cannot
// start, 128+N for a signal, like the shell). stdout and stderr go to out; with merge they share ONE buffer, so
// their lines interleave in the order they were written (`2>&1`); stderr alone goes nowhere (`2>/dev/null`).
func (g *retroGate) bashRun(merge bool, script string, args ...string) (out []byte, rc int) {
	bash, err := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd).LookPath("bash")
	if err != nil {
		return nil, 127
	}
	var buf bytes.Buffer
	cmd := exec.CommandContext(context.Background(), bash, append([]string{script}, args...)...)
	cmd.Env = g.env()
	cmd.Stdout = &buf
	if merge {
		cmd.Stderr = &buf
	}
	err = cmd.Run()
	var ee *exec.ExitError
	switch {
	case err == nil:
		return buf.Bytes(), 0
	case errors.As(err, &ee):
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return buf.Bytes(), 128 + int(ws.Signal())
		}
		return buf.Bytes(), ee.ExitCode()
	}
	return buf.Bytes(), 127
}

// bashCapture is `$(bash script arg 2>/dev/null)`: stdout with NULs dropped and trailing newlines removed.
func (g *retroGate) bashCapture(script, arg string) (string, int) {
	out, rc := g.bashRun(false, script, arg)
	return cmdSub(string(out)), rc
}

// retroSeedable is _retro_is_seedable: the retro has open deltas (review-status pending, none or absent, or
// PARTIAL applied with unshipped rows). The scope, the PARTIAL definition and the out-of-scope guard are the shared
// grammar's (#945, #949, #1093, #1099); an out-of-scope marker fails CLOSED with a typed WARN.
func (g *retroGate) retroSeedable(rf string) bool {
	d, err := retrogrammar.Read(rf)
	sline := ""
	if err == nil {
		sline = retrogrammar.MarkerScopeLine(d)
		if sline == "" && retrogrammar.MarkerOutOfScope(d) {
			g.errf("retro-gate: WARN: out-of-scope-marker: %s — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n", baseName(rf))
			return false
		}
	}
	switch retrogrammar.StatusFromMarkerLine(sline) {
	case "dismissed": // dismissed always wins, never reopened by a stray PARTIAL token
		return false
	case "applied":
		return retrogrammar.MarkerIsPartial(sline)
	}
	return true
}

func (g *retroGate) seedNote(s string) {
	if g.seed != "" {
		g.seed += "; "
	}
	g.seed += s
}

var (
	reCreated  = regexp.MustCompile(`created=[0-9]+`)
	reSkippedD = regexp.MustCompile(`skipped-duplicate=[0-9]+`)
	reFailed   = regexp.MustCompile(`failed=[0-9]+`)
	reUnclass  = regexp.MustCompile(`unclassifiable=[0-9]+`)
	reUnknown  = regexp.MustCompile(`unknown=[0-9]+`)
	reSeedReas = regexp.MustCompile(`^(degraded|DEGRADED|absent-input|input-error):`)
	reProgress = regexp.MustCompile(`^(created|skipped-duplicate|skipped-shipped|skipped-wrong-kit|planned-issue|summary|no-match):`)
)

// numAfter is `grep -oE 'key=[0-9]+' | cut -d= -f2` for the first match: the digits, "" when there is none.
func numAfter(re *regexp.Regexp, s string) string {
	m := re.FindString(s)
	if m == "" {
		return ""
	}
	return m[strings.IndexByte(m, '=')+1:]
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

// linesOf splits seeder output the way grep reads it.
func linesOf(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

// lastWith is `grep '^prefix' | tail -1`.
func lastWith(lines []string, prefix string) string {
	last := ""
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			last = l
		}
	}
	return last
}

func hasLine(lines []string, prefix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// cut80 is `cut -c1-80`: GNU cut counts bytes.
func cut80(s string) string {
	if len(s) > 80 {
		return s[:80]
	}
	return s
}

// runIssueSeeding is _run_issue_seeding (§18-EN3): on session close, every retro with open deltas is handed to
// stage-retro-issues.sh --apply, exactly as the bash ran it (the seeder is its own command; stdout and stderr are
// read as one stream), and the outcome is counted loudly: nothing here ever changes the verdict.
func (g *retroGate) runIssueSeeding() {
	seeder := g.kit + "/toolbelt/stage-retro-issues.sh"
	pr := probe.New([]string{"PATH=" + g.s.Env("PATH")}, g.s.Cwd)
	if _, err := pr.LookPath("gh"); err != nil { // RG-GH-PROBE
		g.errf("retro-gate: WARN: gh not found — issue-seeding skipped (run %s <retro> --apply manually)\n", seeder)
		g.seedNote("skipped:gh-absent")
		return
	}
	if res, err := proc.Run(proc.Spec{Argv: []string{"gh", "auth", "status"}, Env: g.env(), Timeout: ghProbeTimeout, MaxBytes: 1 << 20, Now: g.s.Clock}); err != nil || res.Reason != "" || res.ReturnCode != 0 {
		g.errf("retro-gate: WARN: gh not authenticated — issue-seeding skipped (run gh auth login, then %s <retro> --apply manually)\n", seeder)
		g.seedNote("skipped:gh-not-authenticated")
		return
	}
	if !isRegular(seeder) {
		g.errf("retro-gate: WARN: stage-retro-issues.sh not found at %s — seeding skipped\n", seeder)
		g.seedNote("skipped:seeder-missing")
		return
	}

	var created, skipped, failed, failedIssues, empty, absent, ran, unclassifiable, unknown, unknownIssues int
	failedIssuesUnknown, unknownIssuesUnknown := false, false
	failedList, unknownList := "", ""

	for _, rf := range g.findRetros(false) {
		if rf == "" || g.inNested(rf) || isExcludedRetro(rf) || !g.retroSeedable(rf) {
			continue
		}
		ran++
		b := baseName(rf)
		raw, seedRC := g.bashRun(true, seeder, rf, "--apply")
		seedOut := cmdSub(string(raw))
		lines := linesOf(seedOut)
		seedFailed := "" // per-issue failure count from the summary line; "" = not derivable
		absentTyped := hasLine(lines, "absent-input:")
		summary := lastWith(lines, "summary:")
		switch {
		case absentTyped: // classified FIRST, so an absent-input next to a summary is still absent (#971)
			absent++
			g.errf("retro-gate: WARN: seeder: absent-input for %s (retro not found — verify path)\n", b)
		case summary != "":
			g.errf("retro-gate: seeder %s: %s\n", b, summary)
			g.seedNote(b + " " + summary)
			created += atoi(numAfter(reCreated, summary))
			skipped += atoi(numAfter(reSkippedD, summary))
			// SINGLE SOURCE (#1259): with a summary line its unclassifiable=N is the only count.
			if u := atoi(numAfter(reUnclass, summary)); u > 0 {
				unclassifiable += u
				g.errf("retro-gate: WARN: seeder: %d unclassifiable item(s) for %s — see the unclassifiable-items table and tracking issue in the seeder output (stage-retro-issues.sh <retro>) (kit issue #1259)\n", u, b)
			}
			seedFailed = numAfter(reFailed, summary)
			if hasLine(lines, "no-match:") {
				empty++
			}
		case seedRC == 0:
			switch {
			case hasLine(lines, "empty-input:") || hasLine(lines, "no-match:"):
				empty++
			case hasLine(lines, "unclassifiable:"):
				unclassifiable++
				g.errf("retro-gate: WARN: seeder: unclassifiable for %s — needs manual review, no issue auto-staged — see the unclassifiable-items table and tracking-issue proposal: stage-retro-issues.sh <retro> (kit issue #1111/#1129/#1259)\n", b)
			default:
				g.errf("retro-gate: WARN: seeder exited 0 but no summary: line for %s\n", b)
			}
		default: // no summary and the seeder failed: count the ^created: progress lines as the fallback (§7)
			c := 0
			for _, l := range lines {
				if strings.HasPrefix(l, "created: ") {
					c++
				}
			}
			created += c
			g.errf("retro-gate: WARN: seeder exited %d for %s: no summary: line — counted %d partial-progress line(s)\n", seedRC, b, c)
		}

		// Seeder exit 3 = no failed row but at least one row whose mutation outcome is UNKNOWN; exit 2 = a failed
		// row, and the same run may ALSO hold unknown rows. Both read the seeder's mutation-summary line (#1705).
		if !absentTyped && (seedRC == 2 || seedRC == 3) {
			unkHere, unkWhat := false, "unknown mutation outcome"
			u := numAfter(reUnknown, lastWith(lines, "mutation-summary:"))
			switch {
			case u != "":
				if atoi(u) > 0 {
					unkHere = true
					unknownIssues += atoi(u)
				} else if seedRC == 3 {
					// exit 3 promises >= 1 unknown row; a parsed unknown=0 contradicts it. Never silent.
					unkHere, unknownIssuesUnknown = true, true
					unkWhat = "unknown=contradictory (exit 3, summary unknown=0)"
				}
			case seedRC == 3:
				unkHere, unknownIssuesUnknown = true, true // no parseable mutation-summary: never a fabricated 0
			}
			if unkHere {
				unknown++
				if unknownList != "" {
					unknownList += ", "
				}
				unknownList += b
				g.errf("retro-gate: WARN: seeder exit %d for %s: %s — verify on GitHub, do not retry blindly\n", seedRC, b, unkWhat)
				g.seedNote("seeder-unknown-outcome:" + b)
			}
		}
		if seedRC != 0 && seedRC != 3 && !absentTyped {
			failed++
			// A missing summary, or one with no failed= field, leaves the per-issue count not derivable: unknown,
			// never a silent 0 (#971, §7).
			if seedFailed != "" {
				failedIssues += atoi(seedFailed)
			} else {
				failedIssuesUnknown = true
			}
			if failedList != "" {
				failedList += ", "
			}
			failedList += b
			// The reason (80 bytes): the last typed failure line, else the last non-progress line.
			reason := ""
			for _, l := range lines {
				if reSeedReas.MatchString(l) {
					reason = cut80(l)
				}
			}
			if reason == "" {
				for _, l := range lines {
					if !reProgress.MatchString(l) {
						reason = cut80(l)
					}
				}
			}
			if reason == "" {
				reason = "(no output)"
			}
			g.errf("retro-gate: WARN: seeder failed (exit %d) for %s: %s\n", seedRC, b, reason)
			if hasLine(lines, "degraded:") {
				g.seedNote(fmt.Sprintf("seeder-degraded:%s:%s", b, reason))
			} else {
				g.seedNote(fmt.Sprintf("seeder-failed:rc=%d:%s:%s", seedRC, b, reason))
			}
		}
	}

	// failed-issues reads `unknown` as soon as ONE failed retro had no derivable per-issue count: a partial sum would
	// under-report, so the typed token replaces the number entirely (#971).
	failedTxt := strconv.Itoa(failedIssues)
	if failedIssuesUnknown {
		failedTxt = "unknown"
	}
	if failed > 0 {
		g.errf("retro-gate: WARN: %s issue create(s) failed across %d retro(s): %s\n", failedTxt, failed, failedList)
	}
	unknownTxt := strconv.Itoa(unknownIssues)
	if unknownIssuesUnknown {
		unknownTxt = "unknown"
	}
	if unknown > 0 {
		g.errf("retro-gate: WARN: %s issue create(s) have an UNKNOWN outcome across %d retro(s): %s — verify on GitHub before re-running; never blind-retry\n", unknownTxt, unknown, unknownList)
	}
	g.errf("retro-gate: issue-seeding: ran=%d created=%d skipped-dedup=%d empty=%d unclassifiable=%d absent=%d failed=%d failed-issues=%s target=%s unknown-outcome-retros=%d\n",
		ran, created, skipped, empty, unclassifiable, absent, failed, failedTxt, baseName(g.target), unknown)
	g.seedNote(fmt.Sprintf("ran=%d created=%d skipped-dedup=%d empty=%d unclassifiable=%d absent=%d failed=%d unknown-outcome-retros=%d",
		ran, created, skipped, empty, unclassifiable, absent, failed, unknown))
}
