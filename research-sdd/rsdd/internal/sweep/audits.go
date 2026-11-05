package sweep

import (
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	rg "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Port of research-sdd/toolbelt/sweep-audits.sh (kit issue #2577) and, in audits_hook.go, of
// sweep-audits-hook.sh:
//
//	rsdd sweep audits [--kit <dir>]            the sweep
//	rsdd sweep audits --hook [--kit <dir>] [--full]   the SessionStart hook
//
// The sweep is read-only (it never writes to a target): it lists every PENDING section 13 audit of every target in
// the kit's TARGETS.md, oldest first. An audit acts on the target, so unlike a retro there is no MISSING and no
// WIRING pass here. The shim passes the kit it lives in as --kit, because a binary cannot see the shim's
// location; run directly, the kit is resolved like templates/hook-kit-run.sh does. Like the script, every
// argument other than the flags named above is ignored.
//
// The three states a zero can hide stay distinct (CLAUDE.md section 7): a target directory that is missing is
// "absent-input", one that holds no audit is "empty-input", and audits that all carry a closing marker are
// "no match" (Summary: 0 pending, Nothing to review.).
//
// Declared differences from the script, each pinned by a test:
//
//   - The bash libs it sourced (retro-status, target-paths) are the Go packages core/retrogrammar and core/kit,
//     so the script's "cannot find helper" and "failed to define" exits (case 11 of the old suite) have no
//     equivalent.
//   - A value of RSDD_RETRO_AGE_DAYS that bash `[ -gt ]` refuses (abc, 1.5, an overflow) never escalates, as in
//     the script, but the "integer expression expected" diagnostic of the shell, which names the script and its
//     line, is not printed.
//   - Ties between pending audits of the same age break bytewise (C collation); the script's `sort` used the
//     caller's locale.
//   - A target path with whitespace is split into words and a glob pattern in it is not expanded, as bash did
//     for `for p in $paths` only for the whitespace (the glob is dropped: no real target has one).
//   - An audit that cannot be read reads as one without a marker and with an unknown claim count.
//   - The hook envelope is always JSON (the script printed plain text when jq was missing).
//   - The git calls are bounded (core/git), with the caller's environment.

// RunAudits is the `sweep audits` command.
func RunAudits(args []string, s cli.Stdio) int {
	o, err := parseOptions(args)
	if err != nil {
		return usageFailure(s, o, "audits", auditsHookFailedFmt, err)
	}
	if o.hook {
		return runAuditsHook(o, s)
	}
	return sweepAudits(o, s, s.Out, s.Err)
}

// auditRow is one entry of the oldest-first queue.
type auditRow struct {
	epoch                                  int64
	file, target, claims, status, age, tag string
}

// serial is the row as the script joined it (tab-separated); equal epochs are ordered by it, as `sort` does.
func (r auditRow) serial() string {
	return strings.Join([]string{strconv.FormatInt(r.epoch, 10), r.file, r.target, r.claims, r.status, r.age, r.tag}, "\t")
}

// resolveAuditsKit is resolveKit for a run without --kit: the kit of toolbelt/sweep-audits.sh.
func resolveAuditsKit(o options, s cli.Stdio) (string, error) {
	if o.kit == "" {
		script, _, err := kit.ResolveKitScript("toolbelt/sweep-audits.sh", s.Env)
		if err != nil {
			return "", err
		}
		o.kit = filepath.Dir(filepath.Dir(script))
	}
	return resolveKit(o, s)
}

// auditAgeDays is `${RSDD_RETRO_AGE_DAYS:-7}` as the right operand of `[ n -gt v ]`: bash reads it as a decimal
// integer between optional blanks; anything else is an error, i.e. false, so the audit is never escalated.
func auditAgeDays(v string) int64 {
	if v == "" {
		return 7
	}
	n, err := strconv.ParseInt(strings.Trim(v, " \t\n\v\f\r"), 10, 64)
	if err != nil {
		return math.MaxInt64
	}
	return n
}

// auditAgeDaysOf is `age_d` of an audit first added at epoch: whole days, a date in the future reading as 0.
func auditAgeDaysOf(now, epoch int64) int64 { return max(0, now-epoch) / 86400 }

// auditEscalation is the tag of an audit aged ageD days against the threshold.
func auditEscalation(ageD, threshold int64) string {
	if ageD > threshold {
		return fmt.Sprintf("  ·  ESCALATED (aged %dd)", ageD)
	}
	return ""
}

// addedDateArgs is the git call that dates an audit: the author date of the commit that ADDED the file under its
// current path. --no-renames keeps the answer independent of the diff.renames setting (kit issue #1401); there is
// deliberately no --follow (rename-following costs ~15x per call, the accepted tradeoff of sweep-retros.sh).
func addedDateArgs(f string) []string {
	return []string{"log", "--no-renames", "--diff-filter=A", "--format=%aI", "-1", "--", f}
}

// addedEpoch is the first-commit epoch of f, else its mtime (untracked, or a target that is not a repository),
// else now.
func addedEpoch(g git.Runner, p, f string, now int64) int64 {
	if out, err := g.Run(p, addedDateArgs(f)...); err == nil { // an untracked file prints nothing, which does not parse
		if t, err := time.Parse(time.RFC3339, strings.TrimRight(string(out), "\n")); err == nil {
			return t.Unix()
		}
	}
	if st, err := os.Stat(f); err == nil {
		return st.ModTime().Unix()
	}
	return now
}

// sweepAudits runs the sweep, writing the report to out and the diagnostics to errw. It returns the exit code.
func sweepAudits(o options, s cli.Stdio, out, errw io.Writer) int {
	kitDir, err := resolveAuditsKit(o, s)
	if err != nil {
		fmt.Fprintf(errw, "sweep-audits: %v\n", err)
		return cli.ExitOperational
	}
	targetsMD := kitDir + "/TARGETS.md"
	if st, err := os.Stat(targetsMD); err != nil || !st.Mode().IsRegular() {
		fmt.Fprintf(errw, "sweep-audits: cannot find %s\n", targetsMD)
		return cli.ExitOperational
	}
	src, _ := kit.ReadTargets(targetsMD) // an unreadable file reads as no paths, like the script's silent grep
	var usable, skippedPaths []string
	for _, p := range kit.PathsAll(src, kit.Getenv(s.Env)) {
		if strings.Contains(p, "...") {
			skippedPaths = append(skippedPaths, p)
		} else {
			usable = append(usable, p)
		}
	}
	if len(usable) == 0 {
		fmt.Fprintf(errw, "sweep-audits: ERROR — no usable target paths in %s\n", targetsMD)
		fmt.Fprintf(errw, "sweep-audits: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n")
		return cli.ExitOperational
	}
	skipped, skippedNames := auditSkipped(skippedPaths)

	now := s.Clock().Unix()
	ageDays := auditAgeDays(s.Env("RSDD_RETRO_AGE_DAYS"))
	g := git.Runner{Env: s.Environ(), Timeout: retroGitTimeout, MaxBytes: retroGitMaxBytes, Now: s.Clock}
	seen := map[string]bool{} // canonical paths of the audits already visited (an audit is counted once)
	total, pending, absent := 0, 0, 0
	var rows []auditRow
	for _, p := range strings.Fields(strings.Join(usable, "\n")) { // `for p in $paths`
		if !isDirectory(p) {
			fmt.Fprintf(out, "INFO: corpus not found (absent-input): %s\n", p)
			absent++
			continue
		}
		files := findAudits(p)
		if len(files) == 0 {
			fmt.Fprintf(out, "INFO: corpus exists, no audits found (empty-input): %s\n", p)
			continue
		}
		for _, f := range files {
			key := canonical(f)
			if seen[key] {
				continue
			}
			seen[key] = true
			total++
			status := auditStatus(f)
			if auditClosed(status) {
				continue
			}
			pending++
			epoch := addedEpoch(g, p, f, now)
			ageD := auditAgeDaysOf(now, epoch)
			rows = append(rows, auditRow{epoch: epoch, file: f, target: p, claims: auditClaims(f), status: auditStatusLabel(status),
				age: strconv.FormatInt(ageD, 10), tag: auditEscalation(ageD, ageDays)})
		}
	}

	sortAuditRows(rows)
	writeAuditsReport(out, rows, auditTotals{pending: pending, total: total, absent: absent, skipped: skipped, skippedNames: skippedNames})
	return cli.ExitOK
}

// auditTotals are the counters of one sweep, as the summary prints them.
type auditTotals struct {
	pending, total, absent, skipped int
	skippedNames                    string
}

// writeAuditsReport prints the pending queue, the Summary: line and what follows it.
func writeAuditsReport(out io.Writer, rows []auditRow, t auditTotals) {
	for _, r := range rows {
		fmt.Fprintf(out, "PENDING  %s\n", r.file)
		fmt.Fprintf(out, "         target: %s  ·  ~%s audited claims  ·  status: %s  ·  age: %sd%s\n", r.target, r.claims, r.status, r.age, r.tag)
	}
	fmt.Fprintf(out, "\nSummary: %d pending / %d audits across targets.\n", t.pending, t.total)
	if t.absent > 0 {
		fmt.Fprintf(out, "INFO: %d target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n", t.absent)
	}
	if t.skipped > 0 {
		fmt.Fprintf(out, "WARN: %d target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: %s\n", t.skipped, t.skippedNames)
	}
	// "Nothing to review." only when nothing is pending AND no target was dropped for a truncated path. A target
	// that is absent does not suppress it: the INFO line discloses it and the queue is genuinely empty.
	if t.pending == 0 && t.skipped == 0 {
		io.WriteString(out, "Nothing to review.\n")
	}
	if t.pending > 0 {
		io.WriteString(out, "For each PENDING audit: apply §14 corrections (REFUTED/DOWNGRADED) into the corpus + seed\n"+
			"coverage gaps into the §8 backlog, then flip the marker to\n"+
			"'<!-- review-status: applied <date> · kit <sha> -->' (or 'dismissed').\n")
	}
}

// sortAuditRows is `sort -n -t$'\t' -k1,1`: oldest first by the numeric first-commit epoch, equal epochs in the
// byte order of the whole row (the last-resort comparison of sort in the C locale).
func sortAuditRows(rows []auditRow) {
	sortOldestFirst(rows, func(r auditRow) int64 { return r.epoch }, auditRow.serial)
}

// auditSkipped counts the truncated targets and names them, `for s in $skipped` splitting on whitespace.
func auditSkipped(paths []string) (count int, names string) {
	for _, w := range strings.Fields(strings.Join(paths, "\n")) {
		count++
		if names != "" {
			names += ", "
		}
		names += filepath.Base(w)
	}
	return count, names
}

// isDirectory is `[ -d p ]`: a symbolic link to a directory is one.
func isDirectory(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// auditClosed reports a marker that closes an audit: only applied and dismissed do; any other word, or none,
// leaves it pending.
func auditClosed(status string) bool { return status == "applied" || status == "dismissed" }

// auditStatusLabel is ${status:-none}.
func auditStatusLabel(status string) string {
	if status == "" {
		return "none"
	}
	return status
}

// auditStatus is retro_review_status of an audit: the status word of the marker in its leading block, "" when
// there is none or the file cannot be read.
func auditStatus(f string) string {
	d, err := rg.Read(f)
	if err != nil {
		return ""
	}
	return rg.ReviewStatus(d)
}
