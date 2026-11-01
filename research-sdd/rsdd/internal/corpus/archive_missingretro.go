package corpus

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	archiveReUFOpen  = regexp.MustCompile(`<!-- research-state.v1 -->`)
	archiveReUFClose = regexp.MustCompile(`<!-- /research-state.v1 -->`)
	archiveReDigits  = regexp.MustCompile(`^[0-9]+$`)
)

// archiveUFValue is the awk of the undocumented_findings gate: the second field of the first `undocumented_findings:`
// line inside the research-state.v1 envelope; "" when absent, empty or the file cannot be read.
func archiveUFValue(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	inside := false
	for _, l := range archiveLines(string(b)) {
		if archiveReUFOpen.MatchString(l) {
			inside = true
			continue
		}
		if archiveReUFClose.MatchString(l) {
			inside = false
		}
		if inside {
			f := strings.Fields(l)
			if len(f) > 0 && f[0] == "undocumented_findings:" {
				if len(f) > 1 {
					return f[1]
				}
				return ""
			}
		}
	}
	return ""
}

// archiveUFGate refuses while any inspected state file has undocumented_findings above 0. The scope is the target (a
// split layout keeps one focus per sibling directory), except under --focus. Zero files inspected is an impossible
// state and a typed ERROR, never a pass.
func (e *archiveEnv) archiveUFGate() {
	var src []string
	if e.focus != "" {
		src = []string{e.state}
	} else {
		src = e.archiveListState(e.target)
	}
	count := 0
	for _, sf := range src {
		if !archiveIsFile(sf) {
			continue
		}
		count++
		v := archiveUFValue(sf)
		if v == "" || !archiveReDigits.MatchString(v) || v == "0" {
			continue
		}
		e.say("    undocumented_findings: REFUSE — %s: undocumented_findings=%s must be 0 before closing (write the missing block(s), decrement the counter in the state file, then --sync-state)", filepath.Base(sf), v)
		e.gateRC = 1
	}
	if e.focus != "" {
		e.say("    undocumented_findings: scoped to focus %s — %d of %d state file(s) inspected", e.focus, count, len(e.archiveListState(e.target)))
	}
	if count == 0 {
		e.say("    undocumented_findings: ERROR — could not enumerate state files (impossible: corpus was located but list_state_files returned nothing — inspect lib/state-files.sh)")
		e.gateRC = 1
	}
}

// archiveAddedEpoch is rsdd_added_epoch: the git first-commit (added, under the CURRENT path, no rename following)
// epoch, else the file mtime, else 0. The pathspec is absolute, as the bash passes it.
func (e *archiveEnv) archiveAddedEpoch(dir, f string) string {
	out, _ := e.archiveGit(dir, "log", "--no-renames", "--diff-filter=A", "--format=%ct", "-1", "--", f)
	if v := archiveCmdSub(out); v != "" {
		return v
	}
	if st, err := os.Stat(f); err == nil {
		return strconv.FormatInt(st.ModTime().Unix(), 10)
	}
	return "0"
}

func archiveEpochInt(s string) (int64, bool) {
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return n, err == nil
}

// archiveMissingRetroGate refuses a corpus that has advanced past its newest qualifying §18 retro. It also fills the
// counts the mirror facts and the ONE-BLOCK-PER-COMMIT window reuse.
func (e *archiveEnv) archiveMissingRetroGate() {
	blocks := archiveCorpusBlocks(e.corpus)
	e.blocks = len(blocks)
	for _, bf := range blocks {
		if n, ok := archiveEpochInt(e.archiveAddedEpoch(e.corpus, bf)); ok && n > e.newestBlock {
			e.newestBlock = n
		}
	}
	for _, rf := range archiveRetroPaths(e.corpus, e.target, false) {
		if archiveRetroExcluded(rf) {
			continue
		}
		e.retros++
		n, ok := archiveEpochInt(e.archiveAddedEpoch(e.corpus, rf))
		if !ok {
			continue
		}
		if n > e.newestRetro {
			e.newestRetro = n
		}
		// prior_retro_epoch: the newest qualifying retro at or before the newest block, so a close retro added after the
		// blocks does not shift the ONE-BLOCK-PER-COMMIT window past them
		if n <= e.newestBlock && n > e.priorRetro {
			e.priorRetro, e.priorRetroFile = n, rf
		}
	}
	if e.blocks > 0 && (e.retros == 0 || e.newestBlock > e.newestRetro) {
		date := "none"
		if e.retros != 0 {
			date = e.archiveDate(e.newestRetro)
		}
		e.say("    MISSING-RETRO  : REFUSE — corpus advanced past the newest §18 retro (%s) — delegate a retro before closing (propose-never-apply)", date)
		e.gateRC = 1
	}
}

// archiveDate is `date -d "@N" +%Y-%m-%d`, in the TZ of the environment.
func (e *archiveEnv) archiveDate(epoch int64) string {
	loc := time.Local
	if tz := strings.TrimPrefix(e.s.Env("TZ"), ":"); tz != "" {
		if l, err := time.LoadLocation(tz); err == nil {
			loc = l
		}
	}
	return time.Unix(epoch, 0).In(loc).Format("2006-01-02")
}
