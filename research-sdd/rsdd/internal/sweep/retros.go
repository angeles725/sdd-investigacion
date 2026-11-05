package sweep

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookwiring"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	rg "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Port of research-sdd/toolbelt/sweep-retros.sh (kit issue #2358) and, in retroshook.go, of
// sweep-retros-hook.sh (kit issue #2359):
//
//	rsdd sweep retros [--kit <dir>] [--json]          the sweep
//	rsdd sweep retros --hook [--kit <dir>] [--full]   the SessionStart hook
//
// The sweep is read-only (it never writes to a target): it lists every PENDING retro of every target in the
// kit's TARGETS.md oldest first, then the MISSING-RETRO and WIRING-STATUS passes of the fleet. The shim passes
// the kit it lives in as --kit, because a binary cannot see the shim's location; run directly, the kit is
// resolved like templates/hook-kit-run.sh does. Like the script, every argument other than the flags named
// above is ignored.
//
// Declared differences from the script, each pinned by a test:
//
//   - The bash libs it sourced (retro-status, retro-grammar, target-paths, block-files, hook-wiring) are the Go
//     packages core/retrogrammar, core/kit and core/hookwiring, so the script's "helper missing or failed to
//     define a function" exits (cases 17, 47, 47b, 47c of the old suite) have no equivalent.
//   - --json needs no jq: the envelope is written here, byte for byte as `jq -n` printed it, so the script's
//     typed "jq not found" degraded envelope (exit 3) has no equivalent.
//   - RSDD_PROFILE=1 reads the injected clock; the bash<5 "profile: unavailable (no EPOCHREALTIME)" line has no
//     equivalent. Stdout is written when the command returns (docs/adding-a-command.md), so a caller that merges
//     the two streams sees stderr lines (WARN of an invalid grace value, the profile) before the report.
//   - Ties between pending retros of the same age break bytewise (C collation); the script's `sort` used the
//     caller's locale.
//   - A target path with whitespace is split into words and a glob pattern in it is not expanded, as bash
//     did for `for p in $paths` only for the whitespace (the glob is dropped: no real target has one).
//   - The retros of the whole fleet are read once each; a retro that cannot be read reads as an empty one (the
//     script's helpers discarded the read error, finding F3 of core/retrogrammar).
//   - The git calls are bounded (core/git), with the caller's environment.

const (
	retroGitTimeout  = 10 * time.Minute
	retroGitMaxBytes = 512 << 20
	noSectionDeltas  = "no delta section found (empty-input)"
)

var (
	reProposedHeading = regexp.MustCompile(`^#{2,3}[[:space:]]+(proposed|delta|deltas)`)
	reIDHeading       = regexp.MustCompile(`^#{1,3}[[:space:]]+([a-z][0-9]+|[0-9]+)([[:space:].—–-]|$)`)
)

// options is the parsed command line.
type options struct {
	kit            string
	json, hook, fl bool
}

// parseOptions is the parser shared by retros, audits, tools and breakthroughs. The first problem in argument order
// is returned, but the scan goes on so that o.hook still tells the caller which contract to answer under.
func parseOptions(args []string) (options, error) {
	var o options
	var first error
	fail := func(err error) {
		if first == nil {
			first = err
		}
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			o.json = true
		case "--hook":
			o.hook = true
		case "--full":
			o.fl = true
		case "--kit":
			if i+1 == len(args) {
				fail(fmt.Errorf("--kit needs a directory"))
				continue
			}
			i++
			o.kit = args[i]
		default:
			// Intended divergence (#2687): the scripts dropped an argument they did not know and answered in a
			// mode the caller did not ask for.
			fail(fmt.Errorf("unsupported argument %q", args[i]))
		}
	}
	return o, first
}

// RunRetros is the `sweep retros` command.
func RunRetros(args []string, s cli.Stdio) int {
	o, err := parseOptions(args)
	if err != nil {
		return usageFailure(s, o, "retros", hookFailedFmt, err)
	}
	if o.hook {
		return runRetrosHook(o, s)
	}
	human := io.Writer(s.Out)
	if o.json {
		human = io.Discard
	}
	res := sweepRetros(o, s, human, s.Err)
	if res.rc != 0 {
		return res.rc
	}
	if o.json {
		writeRetrosEnvelope(s.Out, res)
	}
	return cli.ExitOK
}

// pendingRow is one entry of the oldest-first queue.
type pendingRow struct {
	epoch                        int64
	file, target, deltas, dk     string
	status, age, tag, deltaWarns string
}

// serial is the row as the script joined it (\x1f-separated); equal epochs are ordered by it, as `sort` does.
func (r pendingRow) serial() string {
	return strings.Join([]string{strconv.FormatInt(r.epoch, 10), r.file, r.target, r.deltas, r.dk, r.status, r.age, r.tag, r.deltaWarns}, "\x1f")
}

// sweepResult is what the JSON envelope is built from.
type sweepResult struct {
	rc                                          int
	rows                                        []pendingRow
	missing                                     []string
	targets, absent, skipped, total, pendingCnt int
}

// resolveKit is `cd -P -- "$_RSDD_SELF/.." && pwd -P`: the physical kit directory.
func resolveKit(o options, s cli.Stdio) (string, error) {
	k := o.kit
	if k == "" {
		script, _, err := kit.ResolveKitScript("toolbelt/sweep-retros.sh", s.Env)
		if err != nil {
			return "", err
		}
		k = filepath.Dir(filepath.Dir(script))
	}
	if !filepath.IsAbs(k) {
		k = filepath.Join(s.Cwd, k)
	}
	if r, err := filepath.EvalSymlinks(k); err == nil {
		k = r
	}
	return k, nil
}

// graceSeconds is `$(( grace_hours * 3600 ))` of a validated digit string: a leading zero reads as octal and a
// huge value wraps, like bash arithmetic. ok=false is an octal the shell rejects.
func graceSeconds(v string) (int64, bool) {
	base := int64(10)
	if strings.HasPrefix(v, "0") { // "0" reads the same in either base
		base = 8
	}
	var n int64
	for _, c := range []byte(v) {
		d := int64(c - '0')
		if d >= base {
			return 0, false
		}
		n = n*base + d
	}
	return n * 3600, true
}

// profile is the RSDD_PROFILE phase timer: microseconds read from the injected clock.
type profile struct {
	on                              bool
	clock                           func() time.Time
	pend, waiv, wire, rn, bn, total int64
	t0, t0waiv, t0wire, t0total     time.Time
}

func (p *profile) mark() time.Time {
	if !p.on {
		return time.Time{}
	}
	return p.clock()
}

func (p *profile) since(t time.Time) int64 {
	if !p.on {
		return 0
	}
	return p.clock().Sub(t).Microseconds()
}

func profSec(us int64) string { return fmt.Sprintf("%d.%06d", us/1000000, us%1000000) }

// sweepRetros runs the sweep, writing the human report to out and the stderr lines to errw.
func sweepRetros(o options, s cli.Stdio, out, errw io.Writer) sweepResult {
	res := sweepResult{}
	kitDir, err := resolveKit(o, s)
	if err != nil {
		fmt.Fprintf(errw, "sweep-retros: %v\n", err)
		res.rc = cli.ExitOperational
		return res
	}
	targetsMD := kitDir + "/TARGETS.md"
	if st, err := os.Stat(targetsMD); err != nil || !st.Mode().IsRegular() {
		fmt.Fprintf(errw, "sweep-retros: cannot find %s\n", targetsMD)
		res.rc = cli.ExitOperational
		return res
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
	paths := strings.Fields(strings.Join(usable, "\n")) // `for p in $paths` splits on whitespace
	if len(usable) == 0 {
		fmt.Fprintf(errw, "sweep-retros: ERROR — no usable target paths in %s\n", targetsMD)
		fmt.Fprintf(errw, "sweep-retros: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n")
		res.rc = cli.ExitOperational
		return res
	}
	res.targets = len(usable)
	skippedNames := ""
	for _, w := range strings.Fields(strings.Join(skippedPaths, "\n")) {
		res.skipped++
		if skippedNames != "" {
			skippedNames += ", "
		}
		skippedNames += filepath.Base(w)
	}

	now := s.Clock().Unix()
	ageDays := int64(7)
	if v := s.Env("RSDD_RETRO_AGE_DAYS"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			ageDays = n
		} else {
			ageDays = 1<<63 - 1 // `[ n -gt abc ]` is an error, i.e. false: never escalated
		}
	}
	graceHours := s.Env("RSDD_MISSING_RETRO_GRACE_HOURS")
	if graceHours == "" {
		graceHours = "24"
	}
	if !allDigits(graceHours) {
		fmt.Fprintf(errw, "WARN: RSDD_MISSING_RETRO_GRACE_HOURS='%s' is not a non-negative integer — using default 24h\n", graceHours)
		graceHours = "24"
	}
	graceSecs, _ := graceSeconds(graceHours)

	r := &retroRun{
		s: s, out: out, errw: errw, now: now, ageDays: ageDays, graceSecs: graceSecs,
		git:  git.Runner{Env: s.Environ(), Timeout: retroGitTimeout, MaxBytes: retroGitMaxBytes, Now: s.Clock},
		docs: map[string]*rg.Doc{}, seen: map[string]bool{}, unreadable: map[string]bool{},
	}
	prof := profile{on: s.Env("RSDD_PROFILE") == "1", clock: s.Clock}
	prof.t0 = prof.mark()
	prof.t0total = prof.t0

	// Pass 1: the PENDING queue.
	pending := 0
	var rows []pendingRow
	for _, p := range paths {
		if st, err := os.Stat(p); err != nil || !st.IsDir() { // [ -d ] follows a symbolic link
			fmt.Fprintf(out, "INFO: corpus not found (absent-input): %s\n", p)
			res.absent++
			continue
		}
		for _, f := range findRetros(p, true) {
			row, counted, isPending := r.visit(f, p)
			if counted {
				res.total++
			}
			if isPending {
				pending++
				rows = append(rows, row)
			}
		}
	}
	prof.pend += prof.since(prof.t0)

	sortOldestFirst(rows, func(r pendingRow) int64 { return r.epoch }, pendingRow.serial)
	for _, row := range rows {
		fmt.Fprintf(out, "PENDING  %s\n", row.file)
		if row.deltas == noSectionDeltas {
			fmt.Fprintf(out, "         target: %s  ·  %s  ·  status: %s  ·  age: %sd%s\n", row.target, row.deltas, row.status, row.age, row.tag)
		} else {
			fmt.Fprintf(out, "         target: %s  ·  ~%s proposed deltas  ·  status: %s  ·  age: %sd%s\n", row.target, row.deltas, row.status, row.age, row.tag)
		}
		if row.deltaWarns != "" {
			fmt.Fprintf(out, "         WARN: %s\n", row.deltaWarns)
		}
	}

	fmt.Fprintf(out, "\nSummary: %d pending / %d retros across targets.\n", pending, res.total)
	if res.absent > 0 {
		fmt.Fprintf(out, "INFO: %d target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n", res.absent)
	}
	if res.skipped > 0 {
		fmt.Fprintf(out, "WARN: %d target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: %s\n", res.skipped, skippedNames)
	}
	if pending > 0 {
		io.WriteString(out, "For each PENDING retro: review it, apply or dismiss its deltas in the kit,\n"+
			"then set the top marker to '<!-- review-status: applied <date> · kit <sha> -->'.\n"+
			"Note: the count above tracks the review-status MARKER, not whether each delta is open work.\n"+
			"A kit commit may have applied a delta without flipping the marker — an ESCALATED retro is worth\n"+
			"verifying against the kit before treating its full delta count as unresolved.\n")
	}

	// Pass 2: MISSING-RETRO, with the waiver check.
	waivedCount, waivedNames := 0, ""
	prof.t0waiv = prof.mark()
	for _, p := range paths {
		if st, err := os.Stat(p); err != nil || !st.IsDir() {
			continue
		}
		if r.waived(p) {
			waivedCount++
			if waivedNames != "" {
				waivedNames += ", "
			}
			waivedNames += p
			continue
		}
		epochs := r.epochMap(p)
		nr := int64(0)
		t := prof.mark()
		for _, rf := range findRetros(p, true) {
			if rg.IsExcluded(r.doc(rf)) {
				continue
			}
			nr = max(nr, r.epochOf(epochs, p, rf))
		}
		prof.rn += prof.since(t)
		nb := int64(0)
		t = prof.mark()
		blocks, _ := kit.FilterBlockFiles(findMarkdownFiles(p), false, "")
		for _, bf := range blocks {
			nb = max(nb, r.epochOf(epochs, p, bf))
		}
		prof.bn += prof.since(t)
		if nb > nr && now > nb+graceSecs { // nr starts at 0, so nb > nr implies nb > 0
			fmt.Fprintf(out, "MISSING-RETRO: %s advanced with no retro for the latest run\n", p)
			res.missing = append(res.missing, p)
		}
	}
	prof.waiv += prof.since(prof.t0waiv)
	if waivedCount > 0 {
		fmt.Fprintf(out, "waived: %d target(s) — MISSING-RETRO suppressed: %s\n", waivedCount, waivedNames)
	}

	// Pass 3: WIRING-STATUS.
	prof.t0wire = prof.mark()
	var wired, offRoot, unwired, absent, unreadable int
	env := hookwiring.EnvFrom(s)
	for _, p := range paths {
		if st, err := os.Stat(p); err != nil || !st.IsDir() {
			continue
		}
		switch hookwiring.WiringState(env, p) {
		case hookwiring.WiringAbsentSettings:
			fmt.Fprintf(out, "WARN: retro-gate hook absent-settings — no .claude/settings.json: %s\n", p)
			absent++
		case hookwiring.WiringUnreadable:
			fmt.Fprintf(out, "WARN: retro-gate wiring unknown — unreadable: %s/.claude/settings.json\n", p)
			unreadable++
		case hookwiring.WiringWired:
			wired++
		case hookwiring.WiringWiredOffRoot:
			fmt.Fprintf(out, "WARN: retro-gate hook wired-off-root — %s is not its own git root; the hook fires only for a session launched in exactly that directory. Confirm which directory sessions actually launch from and register/wire that directory (kit issue #1134).\n", p)
			offRoot++
		default:
			fmt.Fprintf(out, "WARN: retro-gate not wired in %s/.claude/settings.json\n", p)
			unwired++
		}
	}
	fmt.Fprintf(out, "Wiring: %d wired / %d wired-off-root / %d unwired / %d absent-settings / %d unreadable — %d targets checked.\n",
		wired, offRoot, unwired, absent, unreadable, wired+offRoot+unwired+absent+unreadable)
	prof.wire = prof.since(prof.t0wire)

	if pending == 0 && len(res.missing) == 0 && res.skipped == 0 {
		io.WriteString(out, "Nothing to review.\n")
	}
	if prof.on {
		prof.total = prof.since(prof.t0total)
		fmt.Fprintf(errw, "profile: pending-pass %s\nprofile: waiver-pass %s\nprofile: retro-newest-pass %s\nprofile: block-newest-pass %s\nprofile: wiring-pass %s\nprofile: total %s\n",
			profSec(prof.pend), profSec(prof.waiv), profSec(prof.rn), profSec(prof.bn), profSec(prof.wire), profSec(prof.total))
	}
	res.rows, res.pendingCnt = rows, pending
	return res
}

func allDigits(v string) bool {
	if v == "" {
		return false
	}
	for i := 0; i < len(v); i++ {
		if v[i] < '0' || v[i] > '9' {
			return false
		}
	}
	return true
}

// retroRun carries the state of one sweep.
type retroRun struct {
	s          cli.Stdio
	out        io.Writer
	errw       io.Writer
	now        int64
	ageDays    int64
	graceSecs  int64
	git        git.Runner
	docs       map[string]*rg.Doc
	seen       map[string]bool // canonical paths of the retros already visited (a retro is counted once)
	unreadable map[string]bool // retros that exist but cannot be read: their delta count is unknown
}

// doc reads a retro once. A file that cannot be read is an empty document: the script's helpers read it as
// "no marker, no delta section".
func (r *retroRun) doc(path string) *rg.Doc {
	if d, ok := r.docs[path]; ok {
		return d
	}
	d, err := rg.Read(path)
	if err != nil {
		d = &rg.Doc{Path: path}
		r.unreadable[path] = errors.Is(err, rg.ErrUnreadable)
	}
	r.docs[path] = d
	return d
}

// canonical is `realpath -- f`, or f when it cannot be resolved.
func canonical(f string) string {
	if p, err := filepath.EvalSymlinks(f); err == nil {
		return abs(p)
	}
	dir, base := filepath.Split(f)
	if dir != "" {
		if d, err := filepath.EvalSymlinks(dir); err == nil {
			return abs(d) + "/" + base
		}
	}
	return f
}

func abs(p string) string {
	if a, err := filepath.Abs(p); err == nil {
		return a
	}
	return p
}

// visit handles one retro of the pending pass. counted: it entered the total; pending: it is in the queue.
func (r *retroRun) visit(f, p string) (row pendingRow, counted, pending bool) {
	key := canonical(f)
	if r.seen[key] {
		return row, false, false
	}
	r.seen[key] = true
	d := r.doc(f)
	if rg.IsExcluded(d) {
		return row, false, false
	}
	counted = true
	status := rg.StatusFromMarkerLine(rg.MarkerScopeLine(d))
	if status == "applied" || status == "dismissed" {
		return row, counted, false
	}
	outOfScope := status == "" && rg.MarkerOutOfScope(d)
	base := filepath.Base(f)
	switch status {
	case "pending":
	case "":
		if outOfScope {
			fmt.Fprintf(r.out, "WARN: out-of-scope-marker: %s — a review-status marker exists but sits outside the leading-block scope (kit issue #1099); move it into the leading block\n", base)
		} else {
			fmt.Fprintf(r.out, "WARN: no review-status marker in %s — add '<!-- review-status: pending -->'\n", base)
		}
	default:
		fmt.Fprintf(r.out, "WARN: unrecognized review-status '%s' in %s — only 'applied' or 'dismissed' close a retro\n", status, base)
	}
	deltas, dk, warn := deltaCount(d)
	if r.unreadable[f] { // the lib told the operator once, on stderr, before it read the file as having no section
		fmt.Fprintf(r.errw, "retro-grammar: cannot read %s (unreadable) — delta count is UNKNOWN, not zero\n", f)
	}

	epoch := int64(0)
	haveEpoch := false
	if out, err := r.git.Run(p, "log", "--no-renames", "--diff-filter=A", "--format=%aI", "-1", "--", f); err == nil {
		if added := strings.TrimRight(string(out), "\n"); added != "" {
			if t, err := time.Parse(time.RFC3339, added); err == nil {
				epoch, haveEpoch = t.Unix(), true
			}
		}
	}
	if !haveEpoch {
		if st, err := os.Stat(f); err == nil {
			epoch = st.ModTime().Unix()
		} else {
			epoch = r.now
		}
	}
	ageS := max(0, r.now-epoch)
	ageD := ageS / 86400
	tag := ""
	if ageD > r.ageDays {
		tag = fmt.Sprintf("  ·  ESCALATED (aged %dd)", ageD)
	}
	st := status
	if st == "" {
		st = "none"
	}
	return pendingRow{epoch: epoch, file: f, target: p, deltas: deltas, dk: dk, status: st,
		age: strconv.FormatInt(ageD, 10), tag: tag, deltaWarns: warn}, counted, true
}

// deltaCount decides the "~N proposed deltas" of one retro and its WARN (the section-scoped, doctrine-first
// counting of sweep-retros.sh; the grammar itself is core/retrogrammar). dk is the machine deltas_state.
func deltaCount(d *rg.Doc) (deltas, dk, warn string) {
	info := rg.Delta(d)
	if info.Found {
		switch info.Form {
		case rg.FormTable, rg.FormEntries:
			deltas, dk = strconv.Itoa(info.Count), "counted"
		default:
			if rg.HasHonesty(d) {
				deltas, dk = "0", "counted"
			} else {
				deltas, dk = "?", "uncountable"
				warn = "delta section present but not in countable form — count by hand"
			}
		}
	} else if info.Form == rg.FormH2Delta {
		deltas, dk = strconv.Itoa(info.Count), "counted"
	} else if rawHasDeltaIndicator(d) || info.UnrecFound {
		deltas, dk = "?", "uncountable"
		warn = "non-conforming delta declaration — count by hand"
	} else if rg.HasHonesty(d) {
		deltas, dk = "0", "counted"
	} else {
		deltas, dk = noSectionDeltas, "no-section"
	}
	if info.DeprHeading != "" {
		warn = "deprecated delta heading [" + info.DeprHeading + "] — migrate to '## Proposed kit deltas' per §18"
	}
	return deltas, dk, warn
}

// rawHasDeltaIndicator is the two greps of the script over the file as written (fences and all): a heading
// that names a proposal or a delta, or one that opens with a delta-shaped id.
func rawHasDeltaIndicator(d *rg.Doc) bool {
	for _, l := range d.Raw {
		low := lowerASCII(l)
		if reProposedHeading.MatchString(low) || reIDHeading.MatchString(low) {
			return true
		}
	}
	return false
}

// waived is the waiver scan of the MISSING-RETRO pass: any retro of the target (an index file too) carrying a
// retro-waived marker suppresses the target.
func (r *retroRun) waived(p string) bool {
	for _, wf := range findRetros(p, false) {
		if rg.IsWaived(r.doc(wf)) {
			return true
		}
	}
	return false
}

// epochMap is the one-walk path to first-add-epoch map of a target: `git log` lists newest first and each path
// keeps the value of the OLDEST commit that added it. A target that is not a work tree has no map (nil): its
// files are dated by mtime. Paths are the repository-relative names git prints, so a target below its
// repository root never matches and falls back to mtime, as in the script.
func (r *retroRun) epochMap(p string) map[string]string {
	if _, err := r.git.Run(p, "rev-parse", "--is-inside-work-tree"); err != nil {
		return nil
	}
	m := map[string]string{}
	// A failed log (an empty repository, a timeout) leaves whatever it printed, possibly nothing: the loop below
	// then adds nothing and every file is dated by mtime.
	out, _ := r.git.Run(p, "log", "--no-renames", "--diff-filter=A", "--name-only", "--format=EPOCH:%ct")
	ct := ""
	for _, line := range strings.Split(string(bytes.TrimRight(out, "\n")), "\n") {
		switch {
		case strings.HasPrefix(line, "EPOCH:"):
			ct = strings.TrimPrefix(line, "EPOCH:")
		case line == "":
		case ct != "":
			m[line] = ct
		}
	}
	return m
}

// epochOf is the added-date of a file: its epoch-map entry, else its mtime, else 0.
func (r *retroRun) epochOf(m map[string]string, p, f string) int64 {
	rel := strings.TrimPrefix(f, strings.TrimSuffix(p, "/")+"/")
	if v := m[rel]; v != "" {
		return atoi(v)
	}
	if st, err := os.Stat(f); err == nil {
		return st.ModTime().Unix()
	}
	return 0
}

// atoi is the bash arithmetic of a git epoch: digits only, anything else reads as 0.
func atoi(v string) int64 {
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 0
	}
	return n
}
