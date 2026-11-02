package corpus

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// archiveGates runs every consistency gate in the script's order. A failing gate sets gateRC; none of them stops the
// others, so the refusal lists everything that is wrong.
func (e *archiveEnv) archiveGates() {
	e.say("  -- gates --")
	var vargs []string
	if e.focus != "" {
		vargs = []string{"--focus", e.focus} // AR2: a stale sibling focus must not block a clean one (#647)
	}
	e.archiveGate("verify-state  ", "verify-state.sh", "living mirror inconsistent (stale summary / premature STOP)", vargs...)
	e.archiveGate("verify-sources", "verify-sources.sh", "source registry incomplete (preserved-source markers without a registry, a cited file missing, a fabricated registry citation, or an unregistered web-snapshot)")
	e.archiveVerifyCorrections()
	e.archiveSecretsGate()
	e.archiveUFGate()
	e.archiveMissingRetroGate()
}

// archiveGate is gate(): 0 ok, 1 content failure, anything else = the linter did not run.
func (e *archiveEnv) archiveGate(label, script, msg string, extra ...string) {
	rc := e.archiveSibling(script, append([]string{e.corpus}, extra...)...)
	switch rc {
	case 0:
		e.say("    %s : ok", label)
	case 1:
		e.say("    %s : FAIL — %s", label, msg)
		e.gateRC = 1
	default:
		e.say("    %s : ERROR — %s did not run (exit %d) — check it exists and is executable", label, script, rc)
		e.gateRC = 1
	}
}

// ---- §14 reciprocity gate ----------------------------------------------------------------------------------------

var (
	archiveReFailLine   = regexp.MustCompile(`^ *FAIL `)
	archiveReOKPartial  = regexp.MustCompile(`^ *ok-partial `)
	archiveReOKLine     = regexp.MustCompile(`^ *ok `)
	archiveReAmbigLine  = regexp.MustCompile(`^ *AMBIG `)
	archiveRePartialNum = regexp.MustCompile(`^ *ok-partial ([0-9][0-9]*) `)
	archiveReFailCorr   = regexp.MustCompile(`^ *FAIL +B0*([0-9]+) corrects`)
	archiveReFailTarget = regexp.MustCompile(`^.* but ([^ ]+) has no reciprocal`)
	archiveReFailCorrBy = regexp.MustCompile(`\[correcting: ([^\]]+)\] *$`)
)

// archiveLines splits command output into lines the way grep sees them.
func archiveLines(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(s, "\n"), "\n")
}

func archiveCountMatching(re *regexp.Regexp, lines []string) int {
	n := 0
	for _, l := range lines {
		if re.MatchString(l) {
			n++
		}
	}
	return n
}

func archiveHasMatch(re *regexp.Regexp, lines []string) bool {
	return archiveCountMatching(re, lines) > 0
}

// archiveBlockPrefix is `basename "$1" | sed -E 's/^(.*)-(block|bloque)0*[0-9]+.*/\1/'`: the greedy group takes the last
// "-block<N>" of the basename; a name without one is returned unchanged.
func archiveBlockPrefix(path string) string {
	base := path
	if i := strings.LastIndex(strings.TrimRight(path, "/"), "/"); i >= 0 {
		base = strings.TrimRight(path, "/")[i+1:]
	}
	best := -1
	for i := 0; i < len(base); i++ {
		if base[i] != '-' {
			continue
		}
		if archiveReBlockTail.MatchString(base[i:]) {
			best = i
		}
	}
	if best < 0 {
		return base
	}
	return base[:best]
}

var archiveReBlockTail = regexp.MustCompile(`^-(block|bloque)0*[0-9]+`)

func (e *archiveEnv) archiveVCRefuse(label, detail string) {
	if e.allowVC {
		e.say("    verify-corrections : OVERRIDDEN — %s (--allow-unreciprocated-corrections given; gate NOT enforced)", detail)
		e.warn("WARN: verify-corrections gate overridden by --allow-unreciprocated-corrections — %s.", detail)
		return
	}
	e.say("    verify-corrections : %s — %s (override: --allow-unreciprocated-corrections)", label, detail)
	e.gateRC = 1
}

// archiveVerifyCorrections is the AR-VCORR gate (verify-corrections.sh, issue #1790).
func (e *archiveEnv) archiveVerifyCorrections() {
	raw, rc := e.archiveRunArgv([]string{e.here + "/verify-corrections.sh", e.corpus}, true)
	lines := archiveLines(raw)
	switch rc {
	case 0:
		switch {
		case archiveHasMatch(archiveReOKPartial, lines):
			u := "some"
			for _, l := range lines {
				if m := archiveRePartialNum.FindStringSubmatch(l); m != nil {
					u = m[1]
					break
				}
			}
			e.say("    verify-corrections : PARTIAL — %s declared correction(s) NOT checked (%d typed ambiguous, rest ambiguous/missing target; run verify-corrections.sh for the AMBIG/WARN lines)", u, archiveCountMatching(archiveReAmbigLine, lines))
			e.warn("WARN: verify-corrections ok-partial — %s declared correction(s) could not be checked.", u)
		case archiveHasMatch(archiveReOKLine, lines):
			e.say("    verify-corrections : ok")
		default:
			e.archiveVCRefuse("ERROR", "verify-corrections.sh exited 0 without an 'ok' verdict line (contract drift — the check may not have run)")
		}
	case 1:
		e.archiveVCFindings(lines)
	case 2:
		if strings.Contains(raw, "no block files") {
			e.say("    verify-corrections : n/a — no block files")
		} else {
			e.archiveVCRefuse("ERROR", "verify-corrections.sh did not run (bad args, exit 2) — the §14 reciprocity check was NOT performed")
		}
	default:
		e.archiveVCRefuse("ERROR", "verify-corrections.sh did not run (exit "+strconv.Itoa(rc)+") — check it exists and is executable")
	}
}

func (e *archiveEnv) archiveVCFindings(lines []string) {
	n := archiveCountMatching(archiveReFailLine, lines)
	if deg := archiveFirstMatching(lines, "degraded:"); deg != "" {
		// sed 's/^.*degraded: *//' removes everything up to the LAST "degraded:" on the first such line
		why := strings.TrimLeft(deg[strings.LastIndex(deg, "degraded:")+len("degraded:"):], " ")
		e.archiveVCRefuse("DEGRADED", "verify-corrections.sh reported degraded: "+why)
		return
	}
	if n == 0 {
		e.archiveVCRefuse("ERROR", "verify-corrections exited 1 with no findings (could not run?) — see verify-corrections.sh output")
		return
	}
	var fails []string
	for _, l := range lines {
		if archiveReFailLine.MatchString(l) {
			fails = append(fails, l)
		}
	}
	inFocus, sib, scopeErr := fails, 0, ""
	if e.focus != "" { // AR-VCORR-FOCUS-SCOPE
		fslug := ""
		if fp, err := archiveFocusPrefix(e.state); err == nil {
			fslug = strings.TrimSuffix(fp, "-")
		}
		fcount := 0
		for _, f := range e.archiveFocusBlockFiles() {
			if archiveBlockPrefix(f) == fslug {
				fcount++
			}
		}
		if fslug == "" || fcount == 0 {
			q := fslug
			if q == "" {
				q = "?"
			}
			scopeErr = "cannot scope the §14 gate to focus " + e.focus + " (no block file carries its prefix '" + q + "-'); " + strconv.Itoa(n) + " finding(s) NOT classified"
		} else {
			inFocus = nil
			for _, l := range fails {
				c := ""
				if m := archiveReFailCorr.FindStringSubmatch(l); m != nil {
					c = m[1]
				}
				t := ""
				if m := archiveReFailTarget.FindStringSubmatch(l); m != nil {
					t = m[1]
				}
				cf := ""
				if m := archiveReFailCorrBy.FindStringSubmatch(l); m != nil {
					cf = m[1]
				}
				tp := ""
				if t != "" {
					tp = archiveBlockPrefix(t)
				}
				cp := ""
				if cf != "" {
					cp = archiveBlockPrefix(cf)
				}
				if c == "" || t == "" || cf == "" || tp == fslug || cp == fslug {
					inFocus = append(inFocus, l)
				} else {
					sib++
				}
			}
		}
	}
	if scopeErr != "" {
		e.archiveVCRefuse("ERROR", scopeErr)
		return
	}
	if len(inFocus) > 0 {
		e.archiveVCRefuse("FAIL", strconv.Itoa(len(inFocus))+" one-directional §14 correction(s) — add the reciprocal 'corrected in BN' note to the corrected block(s)")
		for _, l := range inFocus {
			e.say("%s", "      "+strings.TrimLeft(l, " "))
		}
	}
	if sib > 0 {
		e.say("    verify-corrections : SIBLING — %d pair(s) outside focus %s not enforced", sib, e.focus)
		e.warn("WARN: verify-corrections found %d one-directional pair(s) outside focus %s — not enforced for this --focus close.", sib, e.focus)
	}
}

func archiveFirstMatching(lines []string, sub string) string {
	for _, l := range lines {
		if strings.Contains(l, sub) {
			return l
		}
	}
	return ""
}

// archiveFocusBlockFiles is `find corpus -maxdepth 3 -type f -name '*.md' -not -name '*.template.md' -not -path
// '*/.git/*' | block_file_filter`.
func (e *archiveEnv) archiveFocusBlockFiles() []string {
	var cand []string
	for _, p := range archiveFind(e.corpus, 3) {
		st, err := os.Lstat(p)
		if err != nil || !st.Mode().IsRegular() {
			continue
		}
		base := filepath.Base(p)
		if !strings.HasSuffix(base, ".md") || strings.HasSuffix(base, ".template.md") || strings.Contains(p, "/.git/") {
			continue
		}
		cand = append(cand, p)
	}
	return archiveBlockFilter(cand)
}
