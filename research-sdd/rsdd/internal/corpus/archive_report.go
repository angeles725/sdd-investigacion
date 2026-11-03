package corpus

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// archiveReport prints what follows the consolidation: the mirror facts, the ONE-BLOCK-PER-COMMIT advisory, the retro
// format lint and the close checklist (the judgment steps archive refuses to guess).
func (e *archiveEnv) archiveReport() {
	stateText := ""
	if b, err := os.ReadFile(e.state); err == nil {
		stateText = string(b)
	}
	_, histrows := archivePSAScan(stateText, false, 0)
	e.say("  -- mirror facts (for the TARGETS.md row refresh; not applied here) --")
	e.say("    blocks on disk : %d · retros: %d · iteration-history rows: %d", e.blocks, e.retros, histrows)

	oneBlock := e.archiveOneBlockPerCommit()
	e.archiveRetroLint()

	e.say("  -- JUDGMENT follow-ups (NOT mechanizable — do these to complete the close) --")
	if e.consolidateErr != "" {
		e.say("    · ⚠ CONSOLIDATE: %s (a mechanical step failed — fix before relying on the archive).", e.consolidateErr)
	}
	e.say("    · SYNTHESIS block (§8, optional): author a focus-closing block consolidating this focus, if terminal.")
	e.say("    · RETRO (§18): delegate a fresh-context retro agent → %s/retros/<date>-<focus>.md (review-status: pending).", e.target)
	if oneBlock != "" {
		e.say("%s", oneBlock)
	}
	if st, err := os.Lstat(filepath.Join(e.corpus, "codegen")); err == nil && st.IsDir() {
		e.warn("WARN: deliverable (codegen/) present but verify-parity was NOT run — deliverable↔block drift is unchecked;")
		e.warn("      if this is a token/color-based deliverable, run %s/verify-parity.sh <deliverable> <block> before trusting this close.", e.here)
		e.say("    · PARITY (§19): ⚠ codegen/ deliverable present — verify-parity was NOT run here (see WARN above). For")
		e.say("      token/color-based deliverables, run verify-parity.sh <deliverable> <block-or-corpus> per built artifact")
		e.say("      so a drifted/invented value can't ship. NOT auto-gated: the deliverable↔block map is corpus-specific.")
	}
	if histrows > 25 {
		e.say("    · COLLAPSE iteration-history (§8): %d rows > 25 — collapse prior runs to one line/run (blocks, gaps, ratio, retro link).", histrows)
	}
	e.say("    · MIRROR: refresh this target's row in $KIT/TARGETS.md with the counts above (blocks=%d, retros=%d).", e.blocks, e.retros)
	e.say("    · COMMIT (corpus only): git -C %s add -A && git -C %s commit  (orchestrator artifacts stay gitignored, §15).", e.corpus, e.corpus)
	if e.dry {
		e.say("  archived (dry-run — nothing mutated).")
	} else {
		e.say("  archived.")
	}
}

var (
	archiveReMethod = regexp.MustCompile(`method:[ \t]*per-section-agent[ \t]*·[ \t]*[0-9]+[ \t]*sections`)
	archiveReFence  = regexp.MustCompile("^[ \t]*```")
)

// archivePSAScan is the awk over the "## Iteration history" section of a state file. It counts the data rows (a numeric
// first cell; with leading pipe required only when psa is set, the histrows reading does not require it) and, in psa
// mode, returns the N of every `method: per-section-agent · N sections` row whose ordinal exceeds skip. Only table data
// rows outside code fences count for psa; prose, blockquotes and fenced examples never exempt.
func archivePSAScan(text string, psa bool, skip int) (ns []int, rows int) {
	f, fence := false, false
	for _, line := range archiveLines(text) {
		if strings.HasPrefix(line, "## Iteration history") {
			f = true
			continue
		}
		if strings.HasPrefix(line, "## ") {
			f = false
		}
		if !f {
			continue
		}
		l := strings.Trim(line, " \t")
		if psa {
			if archiveReFence.MatchString(line) {
				fence = !fence
				continue
			}
			if fence || !strings.HasPrefix(l, "|") {
				continue
			}
		}
		l = strings.TrimPrefix(l, "|")
		first := strings.Trim(strings.SplitN(l, "|", 2)[0], " \t")
		if !archiveReDigits.MatchString(first) {
			continue
		}
		rows++
		if !psa || rows <= skip {
			continue
		}
		if m := archiveReMethod.FindString(l); m != "" {
			m = strings.TrimRight(strings.TrimSuffix(strings.TrimRight(m, " \t"), "sections"), " \t")
			i := len(m)
			for i > 0 && m[i-1] >= '0' && m[i-1] <= '9' {
				i--
			}
			if n, err := strconv.Atoi(m[i:]); err == nil {
				ns = append(ns, n)
			}
		}
	}
	return ns, rows
}

// archiveOneBlockPerCommit is the advisory detector: any commit of THIS run (newer than the prior retro) that adds two or
// more block files. Pure detection (a WARN and a checklist line, exit stays 0). Returns the checklist line.
//
// A per-section-agent import commit is exempt (kit #1887) when the current run's iteration history records `method:
// per-section-agent · N sections` with N at least the number of blocks the commit adds. The current run is the exact
// boundary: the rows already present in the state file as of the commit that added the prior retro belong to earlier
// runs. When the boundary cannot be determined the exemption fails closed.
func (e *archiveEnv) archiveOneBlockPerCommit() string {
	psaMax := 0
	unevaluable := ""
	if st, err := os.Stat(e.state); err == nil && st.Mode().IsRegular() {
		text, rerr := os.ReadFile(e.state)
		if rerr != nil {
			unevaluable = "state file absent or unreadable"
		} else {
			skip := 0
			if e.priorRetroFile != "" && e.archiveIsGitRepo() {
				skip, unevaluable = e.archivePSASkip()
			}
			if unevaluable == "" {
				ns, _ := archivePSAScan(string(text), true, skip)
				for _, n := range ns {
					if n > psaMax {
						psaMax = n
					}
				}
			}
		}
	} else {
		unevaluable = "state file absent or unreadable"
	}
	var multi, exempt []string
	if e.archiveIsGitRepo() {
		out, _ := e.archiveGit(e.corpus, "log", "--format=%H", "--since=@"+strconv.FormatInt(e.priorRetro, 10))
		for _, sha := range archiveLines(out) {
			if sha == "" {
				continue
			}
			// ADDED block files only (--diff-filter=A, -M forces rename detection whatever diff.renames says), so a
			// backlink edit to an existing block, or a rename, is not a second new block.
			names, _ := e.archiveGit(e.corpus, "show", "--diff-filter=A", "-M", "--name-only", "--format=", sha)
			uniq := map[string]bool{}
			for _, n := range archiveBlockFilter(archiveLines(names)) {
				uniq[n] = true
			}
			if nbf := len(uniq); nbf >= 2 {
				short := sha
				if len(short) > 9 {
					short = short[:9]
				}
				entry := short + "(" + strconv.Itoa(nbf) + " blocks)"
				if psaMax >= nbf {
					exempt = append(exempt, entry)
				} else {
					multi = append(multi, entry)
				}
			}
		}
	}
	if unevaluable != "" && len(multi) > 0 {
		e.say("  note: per-section-agent commit exemption (kit #1887) could not be evaluated — %s", unevaluable)
	}
	if len(exempt) > 0 {
		e.say("  note: import commit(s) %s exempt from ONE-BLOCK-PER-COMMIT (iteration history records method: per-section-agent · %d sections; kit #1887)", strings.Join(exempt, " "), psaMax)
	}
	if len(multi) == 0 {
		return ""
	}
	list := strings.Join(multi, " ")
	e.warn("WARN: ONE-BLOCK-PER-COMMIT violated — commit(s) landing 2+ block files this run: %s", list)
	e.warn("      the loop's LOOP CONTINUATION rule is one block per iteration, one commit per block.")
	return "    · ⚠ ONE-BLOCK-PER-COMMIT (§ LOOP CONTINUATION): commit(s) " + list + " landed 2+ blocks — keep future commits to one block each (this run's history is advisory, not rewritten)."
}

func (e *archiveEnv) archiveIsGitRepo() bool {
	_, rc := e.archiveGit(e.corpus, "rev-parse", "--git-dir")
	return rc == 0
}

// archivePSASkip counts the iteration-history rows of the state file as of the commit that added the prior retro.
func (e *archiveEnv) archivePSASkip() (skip int, unevaluable string) {
	out, _ := e.archiveGit(e.corpus, "log", "--no-renames", "--diff-filter=A", "--format=%H", "-1", "--", e.priorRetroFile)
	sha := archiveCmdSub(out)
	if sha == "" {
		return 0, "the prior retro has no commit, so the run boundary cannot be determined"
	}
	prefix, _ := e.archiveGit(e.corpus, "rev-parse", "--show-prefix")
	spath := archiveCmdSub(prefix) + filepath.Base(e.state)
	tree, rc := e.archiveGit(e.corpus, "ls-tree", "--name-only", sha, "--", spath)
	if rc != 0 {
		return 0, "git ls-tree failed at the prior retro's commit"
	}
	if archiveCmdSub(tree) == "" {
		return 0, "" // the state file did not exist then: every row is current
	}
	old, rc := e.archiveGit(e.corpus, "show", sha+":"+spath)
	if rc != 0 {
		return 0, "git show of the state file at the prior retro's commit failed"
	}
	_, rows := archivePSAScan(old, true, 1<<30)
	return rows, ""
}

// archiveRetroLint warns (advisory) about retros whose review-status marker is malformed or absent: the sweeper gates on
// the LEADING html-comment block, so a bare-text marker is invisible to it.
func (e *archiveEnv) archiveRetroLint() {
	paths := archiveRetroPaths(e.corpus, e.target, true)
	sort.Strings(paths)
	for _, f := range paths {
		if archiveRetroExcluded(f) || archiveRetroStatus(f) != "" {
			continue
		}
		base := filepath.Base(f)
		if archiveRetroBareMarker(f) {
			e.warn("WARN: malformed review-status in %s — bare text marker in first 10 lines; wrap in '<!-- review-status: ... -->'", base)
		} else {
			e.warn("WARN: no review-status marker in leading block of %s — add '<!-- review-status: pending -->' at the top", base)
		}
	}
}
