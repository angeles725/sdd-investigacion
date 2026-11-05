package verify

import (
	"cmp"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/verify/gapdrift"
)

// Port of research-sdd/toolbelt/verify-state.sh: the living-mirror consistency lint of a RESEARCH-STATE.md.
//
//	rsdd verify state <target-dir> [--focus <slug>]
//
// Exit (the script's contract, through the command's ExitMap): 0 consistent, 1 inconsistent (stale mirror: a
// FAIL line was printed), 2 bad arguments, no state file or an absent --focus slug. The report is byte-identical
// to the script's, stdout and stderr. Differences, by design:
//
//   - The child-gap drift check (check-gap-drift.sh) runs in process, through internal/verify/gapdrift: the block files
//     are listed and read once per run instead of once per state file. Its WARN lines are the script's; the checker
//     can no longer be "not found" (RSDD_TOOLBELT_DIR is not read) and is not bounded by a timeout. Where the script
//     itself differs from the Go check, see the package doc of gapdrift.
//   - jq, xargs and realpath are not run; their behaviour is reproduced in process (see statehooks.go), so the
//     "jq not found" and "realpath not found" degraded reports of the P8 scan cannot occur.
//   - The helper libraries cannot be missing, so the script's exit-1 "cannot find helper" guards do not exist,
//     and neither do the "degraded" branches that report a failed awk or grep (counting cannot fail here).
//   - stdout is released when the command ends, stderr as it happens: a caller merging both streams sees the
//     stderr lines first.
//   - An envelope integer with a leading zero is read as octal in the known_gaps identity sum, as bash does; a
//     digit 8 or 9 in one aborts that state's remaining checks with bash's own message (prefixed "verify-state.sh: line N:").

// Stale is the code RunState returns for an inconsistent state; the command table maps it to the legacy 1.
const Stale = 10

const usageLine = "usage: verify-state.sh <target-dir> [--focus <slug>]"

// RunState is `rsdd verify state`.
func RunState(args []string, s cli.Stdio) int {
	fsx := fsView{View: fsview.View{Cwd: s.Cwd}}
	target := ""
	if len(args) > 0 {
		target = args[0]
	}
	if !fsx.IsDir(target) {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	focus := ""
	for rest := args[1:]; len(rest) > 0; {
		if rest[0] != "--focus" || len(rest) < 2 || rest[1] == "" {
			fmt.Fprintln(s.Err, usageLine)
			return cli.ExitUsage
		}
		focus, rest = rest[1], rest[2:]
	}
	var states []string
	if focus != "" {
		abs := fsx.At(target)
		p, _ := kit.ResolveStateFile(abs, kit.ResolveOptions{FollowDir: true, FocusSet: true, Focus: focus})
		if abs != target {
			p = strings.Replace(p, abs, target, 1)
		}
		if p == "" || !fsx.IsFile(p) {
			fmt.Fprintf(s.Err, "verify-state: no RESEARCH-STATE-%s.md found under %s\n", focus, target)
			return cli.ExitUsage
		}
		states = []string{p}
	} else {
		states = fsx.findStates(target)
		if len(states) == 0 {
			fmt.Fprintf(s.Err, "verify-state: no RESEARCH-STATE*.md under %s\n", target)
			return cli.ExitUsage
		}
	}

	hookSet(s.Out, fsx, target)

	v := &verifier{s: s, fs: fsx, target: target}
	rc := 0
	for _, st := range states {
		if !v.checkState(st) {
			rc = 1
		}
	}
	fmt.Fprintf(s.Out, "== exit %d ==\n", rc)
	if rc != 0 {
		return Stale
	}
	return cli.ExitOK
}

type verifier struct {
	s      cli.Stdio
	fs     fsView
	target string
	// blockCounts memoizes countBlocks per directory and prefix: the corpus is read-only for the length of a run
	// and every state file of one directory asked for the same listing and regexp filter (kit issue #2645).
	blockCounts map[blockCountKey]string
	mdListing   map[string][]string
	// gapCorp is the drift check's block-file corpus of the target, opened once per run (kit issue #2645).
	gapCorp   *gapdrift.Corpus
	gapErr    error
	gapOpened bool
}

type blockCountKey struct{ dir, prefix string }

func (v *verifier) echo(format string, a ...any) { fmt.Fprintf(v.s.Out, format+"\n", a...) }

var (
	reCoverageMetric = regexp.MustCompile(`(?i)\*{0,2}coverage metric\*{0,2}:`)
	reRatio          = regexp.MustCompile(`[0-9]+[ \t\n\v\f\r]*/[ \t\n\v\f\r]*[0-9]+`)
	reBacklogAny     = regexp.MustCompile(`(?i)^##[ \t\n\v\f\r].*backlog`)
	reCoveredBlocks  = regexp.MustCompile(`(?i)covered blocks`)
	reBlockID        = regexp.MustCompile(`\bB[0-9]+\b`)
	reIndexHolder    = regexp.MustCompile(`<[A-Z][A-Z0-9_-]*>`)
	reSCProse        = regexp.MustCompile(`(?i)read-only investigable\*{0,2}:[ \t\n\v\f\r]*\*{0,2}[0-9]+`)
	reSCNumber       = regexp.MustCompile(`(?i)investigable\*{0,2}:[ \t\n\v\f\r]*\*{0,2}[0-9]+`)
	reCoverageLine   = regexp.MustCompile(`(?i)coverage metric|declared gaps closed|gaps? closed|coverage \(after`)
	reHistory        = regexp.MustCompile(`^##[ \t\n\v\f\r]+(iteration )?history`)
	reHeading2       = regexp.MustCompile(`^##[ \t\n\v\f\r]`)
	reGapRows        = regexp.MustCompile(`^[ \t\n\v\f\r]*\|[^|]*\|[ \t\n\v\f\r]*B[0-9]+-G[0-9]+`)
)

// checkState lints one state file; false means the run is inconsistent (the script's `rc=1`).
func (v *verifier) checkState(state string) (consistent bool) {
	v.echo("== verify-state: %s (target: %s) ==", shellx.BaseName(state), v.target)
	frc := false
	defer func() {
		// A bash arithmetic error aborts the rest of this state's body (nothing more is printed for it, not even
		// the ok line) and the loop moves on; the exit status keeps whatever the earlier checks had set.
		if r := recover(); r != nil {
			ab, ok := r.(arithAbort)
			if !ok {
				panic(r)
			}
			fmt.Fprintf(v.s.Err, "verify-state.sh: line 1114: %s: value too great for base (error token is \"%s\")\n", ab.tok, ab.tok)
			consistent = !frc
		}
	}()

	raw, err := v.fs.Read(state)
	var lines []string
	hasEnv := false
	if err != nil {
		fmt.Fprintln(v.s.Err, grepError(state, err)) // `grep -q` on an unreadable file: rc 2, "no envelope"
	} else {
		lines = shellx.RecordLines(string(raw))
		for _, l := range lines {
			if reEnvOpen.MatchString(l) {
				hasEnv = true
				break
			}
		}
	}
	if !hasEnv {
		v.echo("   FAIL   no research-state.v1 envelope — run: research-sdd-status.sh %s --sync-state to seed it", v.target)
		v.echo("          Unmigrated state: the counts are not machine-validated, so --next returns STALE until seeded.")
		return false
	}
	src := string(raw)

	rows := backlogRows(src, v.s.Err)
	if len(rows.invalid) > 0 {
		v.echo("   FAIL   backlog NOT FULLY PARSEABLE — unknown priority value(s) found:")
		for _, p := range rows.invalid {
			v.echo("          unknown priority value [%s] — valid: high, medium, low, deferred", p)
		}
		v.echo("          Fix the priority value(s) in the backlog, then re-seed: --sync-state")
		return false
	}

	hasBacklog := false
	for _, l := range lines {
		if strings.HasPrefix(l, "##") && mayContainFold(l, "backlog") && reBacklogAny.MatchString(l) {
			hasBacklog = true
			break
		}
	}
	if !hasBacklog {
		v.echo("   FAIL   ## Gap-backlog section absent — section must be present (even if empty). Add it and re-seed: --sync-state")
		return false
	}

	pending := rows.derivePending()

	metric := ""
	for _, l := range lines {
		if mayContainFold(l, "coverage metric") && reCoverageMetric.MatchString(l) {
			metric = l
			break
		}
	}
	xy := strings.ReplaceAll(reRatio.FindString(metric), " ", "")
	cx, _, _ := strings.Cut(xy, "/")
	cy := xy[strings.LastIndex(xy, "/")+1:]

	coveredClaim := ""
	for _, l := range lines {
		if mayContainFold(l, "covered blocks") && reCoveredBlocks.MatchString(l) {
			if d := reDigits.FindString(l); d != "" {
				coveredClaim = d
				break
			}
		}
	}

	absState := v.fs.At(state)
	fp, _ := kit.DeriveFocusPrefix(absState)
	fpfx := fp.Value
	ondiskUnit := "block file(s) on disk"
	frange := ""
	var rangeVal kit.FocusRange
	if fpfx == "" {
		rangeVal, _ = kit.DeriveFocusRange(absState)
		frange = rangeVal.Value()
		diags, _ := kit.FocusRangeReport(absState)
		for _, d := range diags {
			v.echo("   %s   %s", d.Kind, d.Text)
		}
		if strings.HasPrefix(frange, "!") {
			frange = ""
		}
	}

	eBS := envField(lines, "block_scope")
	bsPresent := envProbe(lines, "block_scope")
	bsValid := true
	if !v.validateBlockScope(bsPresent, eBS) {
		frc, bsValid = true, false
	}
	dir := shellx.DirName(state)
	global := v.countBlocks(dir, "")
	sgAttributed := ""
	sgDone := false
	var ondisk string
	var frname string
	var frfiles string
	switch {
	case bsValid && bsPresent != "" && eBS == "shared-global":
		sgAttributed = fmt.Sprint(deriveAttributedSG(lines))
		ondisk = global
		sgDone = true
	case fpfx != "":
		ondisk = v.countBlocks(dir, fpfx)
	case frange != "":
		lo, hi := rangeVal.Lo, rangeVal.Hi
		scan, _ := kit.ScanFocusRange(v.fs.At(dir), lo, hi, absState)
		ondisk = fmt.Sprint(scan.Count)
		frfiles = fmt.Sprint(scan.Files)
		frname = "B" + frange[:strings.LastIndex(frange, "-")] + "–B" + frange[strings.Index(frange, "-")+1:]
		ondiskUnit = "distinct block id(s) in " + frname
	default:
		ondisk = global
	}

	dInv := fmt.Sprint(rows.deriveInvestigable(blockedNames(blockedBody(lines))))
	dBlocked := fmt.Sprint(blockedOpenCount(lines))
	dReq := rows.deriveRequiresExecution()
	dDef := deriveDeferred(src, v.s.Err)
	eCovered := envField(lines, "covered_blocks")
	eInv := envField(lines, "investigable_open")
	eBlocked := envField(lines, "blocked_open")
	eReq := envField(lines, "requires_execution_open")
	eDef := envField(lines, "deferred_open")
	eGC := envField(lines, "gaps_closed")
	eKG := envField(lines, "known_gaps")
	eUF := envField(lines, "undocumented_findings")
	ufPresent := envProbe(lines, "undocumented_findings")
	eBSR := envField(lines, "blocks_since_retro")
	bsrPresent := envProbe(lines, "blocks_since_retro")
	eKSW := knownStaleWarns(lines)
	kswHas := func(id string) bool {
		for _, t := range strings.Split(eKSW, ",") {
			if strings.Trim(t, shellx.WsClass) == id {
				return true
			}
		}
		return false
	}

	or := func(s, d string) string {
		if s == "" {
			return d
		}
		return s
	}
	v.echo("-- summary --")
	v.echo("   coverage metric : %s", or(xy, "<none>"))
	v.echo("   covered blocks  : %s claimed · %s %s", or(coveredClaim, "<none>"), ondisk, ondiskUnit)
	v.echo("   backlog pending : %d", pending)
	v.echo("   envelope        : covered_blocks=%s/%s · investigable_open=%s/%s · requires_execution_open=%s/%d · blocked_open=%s/%s · deferred_open=%s/%d · undocumented_findings=%s  (declared/derived; undocumented_findings is manually-maintained)",
		or(eCovered, "<none>"), ondisk, or(eInv, "<none>"), dInv, or(eReq, "<none>"), dReq, or(eBlocked, "<none>"), dBlocked, or(eDef, "<none>"), dDef, or(eUF, "<none>"))
	if retyped := rows.retyped(); len(retyped) > 0 {
		v.echo("   re-typed in table : %d — counted in no bucket", len(retyped))
		for _, g := range retyped {
			v.echo("   WARN   re-typed row still carries \"re-typed\" — write its Status as the re-typed form \"blocked (requires-<what>)\" per METHODOLOGY §8b (or move it to the Blocked-gaps section) [gap: %s]", g)
		}
	}

	if sgDone {
		v.echo("   INFO   corpus total %s block file(s) (shared-global, informational)", global)
		if intEQ(or(sgAttributed, "0"), 0) {
			v.echo("   INFO   covered_blocks unverifiable under shared-global: no attributed block ids listed")
		} else if !isInt(eCovered) || eCovered != sgAttributed {
			v.echo("   FAIL   envelope covered_blocks=%s != %s attributed block(s) under shared-global — re-seed: --sync-state", or(eCovered, "<missing>"), sgAttributed)
			frc = true
		}
	}
	cannotSee := bsValid && eBS != "shared-global"
	if !sgDone && (!isInt(eCovered) || eCovered != ondisk) {
		switch {
		case fpfx != "" && intEQ(or(ondisk, "0"), 0) && intGT(or(global, "0"), 0) && cannotSee:
			v.echo("   FAIL   envelope covered_blocks=%s: no block file matches prefix '%s' — %s block file(s) exist under other prefixes; if the corpus uses shared block numbering across focuses, declare block_scope: shared-global then re-seed: --sync-state", or(eCovered, "<missing>"), fpfx, global)
		case frange != "" && intEQ(or(ondisk, "0"), 0) && intGT(or(global, "0"), 0) && cannotSee:
			v.echo("   FAIL   envelope covered_blocks=%s: no block file is numbered within %s (FOCUSES.md range) — %s block file(s) exist outside it; fix the range cell or declare block_scope: shared-global, then re-seed: --sync-state", or(eCovered, "<missing>"), frname, global)
		case frange != "":
			v.echo("   FAIL   envelope covered_blocks=%s != %s distinct block ids in %s (%s block file(s)) — re-seed: --sync-state", or(eCovered, "<missing>"), ondisk, frname, or(frfiles, "0"))
		default:
			v.echo("   FAIL   envelope covered_blocks=%s != %s block file(s) on disk — re-seed: --sync-state", or(eCovered, "<missing>"), ondisk)
		}
		frc = true
	}
	if isInt(eCovered) && eCovered == ondisk && fpfx != "" && intEQ(or(ondisk, "0"), 0) && intGT(or(global, "0"), 0) && cannotSee {
		v.echo("   WARN   envelope covered_blocks=0: declared 0 matches 0 focus-filtered on-disk — but %s block file(s) exist under other prefixes (focus '%s' matches none); if the corpus uses shared block numbering across focuses, declare block_scope: shared-global then re-seed: --sync-state", global, fpfx)
	}
	if isInt(eCovered) && eCovered == ondisk && frange != "" && intEQ(or(ondisk, "0"), 0) && intGT(or(global, "0"), 0) && cannotSee {
		v.echo("   WARN   envelope covered_blocks=0: declared 0 matches 0 in-range on-disk — but %s block file(s) exist outside %s (the range scopes none of them); fix the range cell or declare block_scope: shared-global, then re-seed: --sync-state", global, frname)
	}
	if !isInt(eInv) || eInv != dInv {
		v.echo("   FAIL   envelope investigable_open=%s != %s NEXT-eligible pending gap(s) — re-seed: --sync-state", or(eInv, "<missing>"), dInv)
		v.echo("          A stale investigable_open is the premature-STOP hazard; verify-state refuses to certify it.")
		frc = true
	}
	if !isInt(eBlocked) || eBlocked != dBlocked {
		v.echo("   FAIL   envelope blocked_open=%s != %s blocked entr(y/ies) — re-seed: --sync-state", or(eBlocked, "<missing>"), dBlocked)
		frc = true
	}
	if isInt(eGC) && isInt(eKG) && intGT(eKG, 0) && eGC == eKG && isInt(dInv) && intGT(dInv, 0) {
		v.echo("   FAIL   envelope gaps_closed=%s == known_gaps=%s while %s investigable gap(s) remain — premature-STOP hazard.", eGC, eKG, dInv)
		frc = true
	}
	switch {
	case isInt(eReq) && intEQ(eReq, 0) && dReq > 0:
		v.echo("   FAIL   envelope requires_execution_open=0 (build loop declared done) while %d open requires-execution backlog gap(s) remain — premature build-STOP hazard; re-seed --sync-state.", dReq)
		frc = true
	case isInt(eReq) && dReq > 0 && eReq != fmt.Sprint(dReq):
		v.echo("   WARN   envelope requires_execution_open=%s != %d marked-open requires-execution backlog gap(s) — mirror hygiene; re-seed --sync-state.", eReq, dReq)
	case !isInt(eReq):
		v.echo("   WARN   envelope requires_execution_open=%s is not an integer — seed it: --sync-state.", or(eReq, "<missing>"))
	}
	if isInt(eDef) {
		if eDef != fmt.Sprint(dDef) {
			v.echo("   FAIL   envelope deferred_open=%s != %d deferred backlog gap(s) — re-seed: --sync-state", eDef, dDef)
			frc = true
		}
	} else if dDef > 0 {
		v.echo("   WARN   envelope deferred_open missing while %d deferred backlog gap(s) found — seed it: --sync-state", dDef)
	}

	if isInt(eGC) && isInt(eKG) && isInt(eInv) && isInt(eBlocked) && isInt(eReq) {
		hDef := "0"
		if isInt(eDef) {
			hDef = eDef
		}
		dIPB := kit.InplaceBlockedCount(blockedBody(lines), rows.rowsText())
		sum := arithSum(eGC, eInv, eBlocked, hDef, eReq, fmt.Sprint(dIPB))
		if kg, ok := shellx.Decimal(eKG); ok && sum != kg {
			if dIPB > 0 {
				v.echo("   WARN   envelope known_gaps=%s != sum of declared counters (gaps_closed+investigable_open+blocked_open+deferred_open+requires_execution_open)+in_place_blocked(derived: %d open blocked backlog row(s) not in blocked_open)=%d — stale denominator; reconcile.", eKG, dIPB, sum)
			} else {
				v.echo("   WARN   envelope known_gaps=%s != sum of declared counters (gaps_closed+investigable_open+blocked_open+deferred_open+requires_execution_open)=%d — stale denominator; reconcile.", eKG, sum)
			}
		}
	}

	body := blockedBody(lines)
	if n := missingTried(body); n > 0 {
		v.echo("   WARN   %d blocked gap(s) missing a tried: clause (alternatives considered + what measurement closed each) — document before closing as absent-input.", n)
	}
	miss, ord := missingUnblock(body)
	if miss > 0 {
		v.echo("   WARN   %d blocked gap(s) missing an unblock: line (unblock: <route> · owner: <who> · cost: <estimate>; presence-only check) — a wall is a waypoint; METHODOLOGY §21.1.", miss)
	}
	if ord > 0 {
		v.echo("   WARN   %d blocked gap(s) with unblock: placed before needs: — the plan goes AFTER needs:/tried: (METHODOLOGY §21.1).", ord)
	}
	if n := rows.missingUnblockRows(body); n > 0 {
		v.echo("   WARN   %d wall backlog row(s) missing an unblock: plan at the end of the Status cell (presence-only check; a row linked by name or gap ID to a ## Blocked gaps bullet is exempt) — METHODOLOGY §21.1.", n)
	}
	if m := stretchMissing(lines); m != "" && m != "absent" {
		v.echo("   WARN   ## Stretch goal section present but missing %s line(s) — add them per the PROMPT-LOOP BOOTSTRAP template (kit #1268).", strings.ReplaceAll(m, " ", " and "))
	}

	switch {
	case ufPresent != "" && !isInt(eUF):
		v.echo("   FAIL   envelope undocumented_findings=%s is not a valid non-negative integer — the archive gate cannot check debt.", or(eUF, "<unparseable>"))
		v.echo("          Correct the value manually in the envelope first (change it to a non-negative integer);")
		v.echo("          then re-seed with --sync-state. Running --sync-state without fixing the value first")
		v.echo("          will warn and carry the bad value forward — it will NOT zero it — but verify-state")
		v.echo("          will continue to FAIL until the value is a valid non-negative integer.")
		frc = true
	case isInt(eUF) && intGT(eUF, 6):
		v.echo("   FAIL   envelope undocumented_findings=%s > 6 — write the missing block(s), decrement to 0, re-seed: --sync-state. Memory is a MIRROR, not the record.", eUF)
		frc = true
	case isInt(eUF) && intGT(eUF, 3):
		v.echo("   WARN   envelope undocumented_findings=%s > 3 — findings exist only in memory (no block); write the block(s) and decrement.", eUF)
	}
	switch {
	case bsrPresent != "" && !isInt(eBSR):
		v.echo("   FAIL   envelope blocks_since_retro=%s is not a valid non-negative integer — fix the value manually.", or(eBSR, "<unparseable>"))
		frc = true
	case isInt(eBSR) && intGT(eBSR, 10):
		v.echo("   WARN   envelope blocks_since_retro=%s > 10 — §18 retro cadence exceeded; write a retro and reset to 0.", eBSR)
	}

	idx := dir + "/INDEX.md"
	if intGT(or(ondisk, "0"), 0) && v.fs.IsFile(idx) {
		if b, err := v.fs.Read(idx); err == nil && matchesAnyLine(reIndexHolder, string(b)) {
			if kswHas("p7-index-placeholder") {
				v.echo("   INFO   INDEX.md placeholder WARN suppressed (known_stale_warns: p7-index-placeholder)")
			} else {
				v.echo("   WARN   INDEX.md still contains template placeholders (e.g. <SUBJECT>, <YYYY-MM-DD>) while %s %s — update the corpus index.", ondisk, ondiskUnit)
			}
		}
	}

	if prose := firstLineMatching(lines, reSCProse, func(l string) bool { return mayContainFold(l, "investigable") }); prose != "" {
		var nums []string
		for _, m := range reSCNumber.FindAllString(prose, -1) {
			nums = append(nums, reDigits.FindString(m)) // m is `investigable:` plus one run of digits
		}
		scN := strings.Join(nums, "\n")
		if scN != "" && scN != dInv {
			v.echo("   FAIL   stop-control prose 'read-only-investigable: %s' but backlog derives %s investigable gap(s) — refresh the Stop control section and re-seed: --sync-state", scN, dInv)
			frc = true
		}
	}

	if cx != "" && cy != "" && cx == cy && pending > 0 {
		v.echo("   FAIL   summary claims ALL %s gaps closed, but the backlog lists %d 'pending' gap(s).", cy, pending)
		v.echo("          Stale mirror — this desync is what lets the loop emit a PREMATURE STOP. Refresh the")
		v.echo("          coverage metric (or reopen it) so it matches the backlog before honoring any STOP.")
		frc = true
	}

	if coveredClaim != "" && intGT(or(ondisk, "0"), 0) && !sgDone && coveredClaim != ondisk {
		if kswHas("check-2-covered-blocks") {
			v.echo("   INFO   covered-blocks mismatch WARN suppressed (known_stale_warns: check-2-covered-blocks)")
		} else {
			v.echo("   WARN   'Covered blocks: %s' disagrees with %s %s — refresh the mirror.", coveredClaim, ondisk, ondiskUnit)
		}
	}

	if denoms := coverageDenominators(lines); len(denoms) >= 2 {
		v.echo("   WARN   contradictory coverage denominators (%s) — collapse to one canonical coverage number", strings.Join(denoms, " vs "))
	}

	// A short cut, not the row parser (gapDrift parses the rows itself): it skips the check, and the corpus open it
	// needs, for a file with no gap row, so an unopenable corpus only warns where a row cites it.
	for _, l := range lines {
		if reGapRows.MatchString(l) {
			v.gapDrift(state, src)
			break
		}
	}

	if !frc {
		v.echo("   ok     envelope validated + summary consistent with the backlog.")
	}
	return !frc
}

func (v *verifier) validateBlockScope(present, bs string) bool {
	if present == "" {
		return true
	}
	switch bs {
	case "per-focus", "shared-global":
		return true
	case "":
		v.echo("   FAIL   envelope block_scope is present but unparseable — check for a missing space after the colon (e.g. 'block_scope:shared-global' must be 'block_scope: shared-global') — must be 'per-focus' or 'shared-global'")
	default:
		v.echo("   FAIL   envelope block_scope=%s is not a legal value — must be 'per-focus' or 'shared-global'", bs)
	}
	return false
}

// countBlocks is `find DIR -maxdepth 1 -type f -name '*.md' | block_file_filter [PREFIX] | wc -l`.
func (v *verifier) countBlocks(dir, prefix string) string {
	key := blockCountKey{dir, prefix}
	if n, ok := v.blockCounts[key]; ok {
		return n
	}
	n := v.countBlocksUncached(dir, prefix)
	if v.blockCounts == nil {
		v.blockCounts = map[blockCountKey]string{}
	}
	v.blockCounts[key] = n
	return n
}

// mdLines is the regularMarkdown listing of dir as the lines the block filter reads, listed once per run.
func (v *verifier) mdLines(dir string) []string {
	if l, ok := v.mdListing[dir]; ok {
		return l
	}
	var b strings.Builder
	for _, f := range v.fs.regularMarkdown(dir) {
		b.WriteString(f + "\n")
	}
	l := kit.SplitLines(b.String())
	if v.mdListing == nil {
		v.mdListing = map[string][]string{}
	}
	v.mdListing[dir] = l
	return l
}

// literalPrefix reports whether a focus prefix is plain ERE literals ([A-Za-z0-9_-] only), for which a line can
// match `(^|/)PREFIX(block|bloque)...` only if it contains PREFIX.
func literalPrefix(p string) bool {
	for i := 0; i < len(p); i++ {
		c := p[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func (v *verifier) countBlocksUncached(dir, prefix string) string {
	lines := v.mdLines(dir)
	if literalPrefix(prefix) { // an empty prefix is literal too: every line contains it
		// A cheap necessary condition first: the POSIX regexp then runs only on the plausible lines (#2645).
		var keep []string
		for _, l := range lines {
			if strings.Contains(l, prefix) {
				keep = append(keep, l)
			}
		}
		lines = keep
	}
	out, _ := kit.FilterBlockFiles(lines, false, prefix)
	return fmt.Sprint(len(out))
}

// deriveAttributedSG is _derive_attributed_sg: distinct B<n> ids of the `## Covered blocks` section, else of the
// Block column of the `## Iteration history` table.
func deriveAttributedSG(lines []string) int {
	ids := map[string]bool{}
	for _, l := range section(lines, "## Covered blocks") {
		for _, m := range reBlockID.FindAllString(l, -1) {
			ids[m] = true
		}
	}
	if len(ids) == 0 {
		blockcol := 0
		for _, l := range section(lines, "## Iteration history") {
			if !strings.Contains(l, "|") {
				continue
			}
			l = strings.TrimSuffix(l, "\r")
			a := strings.Split(strings.ReplaceAll(l, `\|`, "\x01"), "|")
			if blockcol == 0 {
				for i, c := range a {
					if asciiLower(trimBlanks(c)) == "block" {
						blockcol = i + 1
						break
					}
				}
				continue
			}
			if len(a) >= blockcol {
				for _, m := range reBlockID.FindAllString(trimBlanks(a[blockcol-1]), -1) {
					ids[m] = true
				}
			}
		}
	}
	return len(ids)
}

// knownStaleWarns is KSW-EXTRACT: the value of the envelope's known_stale_warns line.
func knownStaleWarns(lines []string) string {
	l, ok := scanEnvelope(lines, func(l string) bool {
		return strings.HasPrefix(strings.TrimLeft(l, shellx.WsClass), "known_stale_warns:")
	})
	if !ok {
		return ""
	}
	val := strings.TrimPrefix(strings.TrimLeft(l, shellx.WsClass), "known_stale_warns:")
	return strings.TrimRight(strings.TrimLeft(val, shellx.WsClass), shellx.WsClass)
}

func matchesAnyLine(re *regexp.Regexp, text string) bool {
	return firstLineMatching(shellx.RecordLines(text), re, func(l string) bool { return strings.Contains(l, "<") }) != ""
}

// firstLineMatching is `grep -E ... | head -1`; may is a cheap necessary condition tested before the regexp
// (kit issue #2645).
func firstLineMatching(lines []string, re *regexp.Regexp, may func(string) bool) string {
	for _, l := range lines {
		if may(l) && re.MatchString(l) {
			return l
		}
	}
	return ""
}

// coverageDenominators is CHECK 3: the distinct denominators (numeric order) of the coverage lines outside the
// history sections.
func coverageDenominators(lines []string) []string {
	inHist := false
	var den []string
	for _, l := range lines {
		h2 := strings.HasPrefix(l, "##") // both heading regexps are anchored on "##"
		if h2 && reHistory.MatchString(asciiLower(l)) {
			inHist = true
			continue
		}
		if h2 && reHeading2.MatchString(l) {
			inHist = false
		}
		if inHist || !mayContainFold(l, "closed", "coverage metric", "coverage (after") || !reCoverageLine.MatchString(l) {
			continue
		}
		m := reRatio.FindString(l)
		if m == "" {
			continue
		}
		den = append(den, strings.TrimLeft(m[strings.LastIndex(m, "/")+1:], shellx.WsClass))
	}
	sort.SliceStable(den, func(i, j int) bool { return numLess(den[i], den[j]) })
	var out []string
	for i, d := range den {
		if i > 0 && !numLess(den[i-1], d) {
			continue
		}
		out = append(out, d)
	}
	return out
}

// numLess compares digit strings numerically at any length, like `sort -n`.
func numLess(a, b string) bool {
	a, b = strings.TrimLeft(a, "0"), strings.TrimLeft(b, "0")
	return cmp.Or(cmp.Compare(len(a), len(b)), strings.Compare(a, b)) < 0
}

// arithAbort is the abort of a bash arithmetic expansion over a leading-zero integer holding an 8 or 9.
type arithAbort struct{ tok string }

// arithSum is $(( a + b + ... )) over is_int strings: a leading zero makes the value octal, wrapping at 64 bits.
func arithSum(vals ...string) int64 {
	var sum uint64
	for _, s := range vals {
		base := uint64(10)
		digits := s
		if strings.HasPrefix(s, "0") {
			base, digits = 8, s[1:]
		}
		var n uint64
		for i := 0; i < len(digits); i++ {
			d := uint64(digits[i] - '0')
			if d >= base {
				panic(arithAbort{tok: s})
			}
			n = n*base + d
		}
		sum += n
	}
	return int64(sum)
}

// gapDrift runs the child-gap drift check in process (WARN-only; a failing check is a typed degraded WARN, never
// silence). The block-file listing and every block file are read once per target for the whole run, not once per state
// file as the check-gap-drift.sh subprocess did (kit issue #2645).
func (v *verifier) gapDrift(state, src string) {
	out, rc := v.gapDriftReport(state, src)
	relayGapDrift(v.echo, out, rc)
}

// gapDriftReport is the check's merged report (trailing newlines removed) and exit code: what the script printed
// on stdout and stderr, and its exit status.
func (v *verifier) gapDriftReport(state, src string) (string, int) {
	corpus, err := v.gapCorpus()
	if err == nil {
		var res gapdrift.Result
		if res, err = corpus.Check(src, state, gapdrift.Options{Threshold: gapdrift.DefaultThreshold}); err == nil {
			var b strings.Builder
			res.Render(&b)
			return cmdSubst(b.String()), res.ExitCode()
		}
	}
	return cmdSubst(err.Error()), cli.ExitUsage
}

// gapCorpus is the block-file side of the target, opened once per run.
func (v *verifier) gapCorpus() (*gapdrift.Corpus, error) {
	if v.gapOpened {
		return v.gapCorp, v.gapErr
	}
	v.gapCorp, v.gapErr = gapdrift.OpenCorpus(v.s.Cwd, v.target)
	v.gapOpened = true
	return v.gapCorp, v.gapErr
}

// relayGapDrift turns the check's report into WARN lines: each finding line (DRIFT?, UNPARSED, DEGRADED) is relayed,
// and a failure of the check itself (exit 2, or exit 1 with no finding line) is a typed degraded WARN.
func relayGapDrift(echo func(format string, a ...any), out string, rc int) {
	typed := false
	for _, l := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(l, "DRIFT?") || strings.HasPrefix(l, "UNPARSED"):
			typed = true
			echo("   WARN   gap-drift: %s — copy the child-gap text verbatim from the block bullet (METHODOLOGY §7)", l)
		case strings.HasPrefix(l, "DEGRADED"):
			echo("   WARN   gap-drift: %s", l)
		}
	}
	if rc >= 2 || (rc == 1 && !typed) {
		first, _, _ := strings.Cut(out, "\n")
		echo("   WARN   gap-drift: degraded — check-gap-drift.sh failed (exit %d): %s", rc, first)
	}
}
