package skilldrift

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Kit staleness (kit issue #2130): the kit this hook runs from is a mutable shared checkout that silently falls behind
// origin/main, and the shared checkout is deliberately not auto-updated while research sessions run. ONE typed `stale` line (the
// fix command FIRST, the prose after, so a width cut never chops the command) when it is behind its upstream by more than
// RESEARCH_SDD_KIT_STALE_MAX_COMMITS (default 20) or the last fetch is older than RESEARCH_SDD_KIT_STALE_MAX_DAYS (default 7).
//
// LOCAL refs only: no fetch in a SessionStart hook, so the count may understate. ALL the git work shares ONE bound of 3 seconds:
// the worst case is install's bound plus 3 s, never per call (every run is a core/git run, which stops its whole process group).
// A timed-out or failed measurement leaves the state UNKNOWN, so install's own behind line is kept. UNMEASURABLE (git missing, not
// a checkout, no upstream, git stalled) stays SILENT at SessionStart, like install --verify's own `kit status=degraded`
// (un-clearable there); RESEARCH_SDD_KIT_STALE_VERBOSE=1 prints it as a typed `verify kit-stale status=degraded reason=...` line.
// The age comes from the FETCH_HEAD mtime only (never .git/config: any `git config` write resets it).

const (
	staleBound        = 3 * time.Second
	staleWidth        = 200 // characters of the stale line
	defaultMaxCommits = 20
	defaultMaxDays    = 7
)

// staleResult is what _rsdd_kit_stale leaves behind.
type staleResult struct {
	state string // "ok", "stale" or "unknown"
	line  string // the stale line, when stale
	note  string // announcements of invalid thresholds
	deg   string // the verbose-only degraded line
}

var sanitizeRe = regexp.MustCompile(`[^A-Za-z0-9._-]`)

// sanitize is `tr -cd '[:alnum:]._-' | cut -c1-30`.
func sanitize(v string) string {
	v = sanitizeRe.ReplaceAllString(v, "")
	if len(v) > 30 {
		v = v[:30]
	}
	return v
}

// threshold reads a numeric threshold: unset gives the default, a set value must be 1 to 6 decimal digits (it is validated
// BEFORE any use, never evaluated), and an invalid one is announced and replaced.
func threshold(e envView, key string, def int, notes *[]string) int {
	v, set := e.lookup(key)
	if !set {
		return def
	}
	valid := v != "" && len(v) < 7
	for _, r := range v {
		if r < '0' || r > '9' {
			valid = false
		}
	}
	if !valid {
		*notes = append(*notes, fmt.Sprintf("verify kit-stale: invalid %s='%s', using %d", key, sanitize(v), def))
		return def
	}
	n, _ := strconv.Atoi(v) // base 10: "007" is 7, not octal
	return n
}

// kitStale is _rsdd_kit_stale. mtime reads a file's modification time in seconds.
func kitStale(e envView, here string, now func() time.Time, mtime func(string) (int64, error)) staleResult {
	r := staleResult{state: "unknown"}
	kdir := e.get("RESEARCH_SDD_KIT_DIR")
	if kdir == "" {
		kdir = filepath.Join(here, "..")
	}
	var notes []string
	kmax := threshold(e, "RESEARCH_SDD_KIT_STALE_MAX_COMMITS", defaultMaxCommits, &notes)
	kdays := threshold(e, "RESEARCH_SDD_KIT_STALE_MAX_DAYS", defaultMaxDays, &notes)
	r.note = strings.Join(notes, "\n")

	m := measure(e, kdir, kmax, kdays, now, mtime)
	if m.state != "" {
		r.state, r.line = m.state, m.line
	}
	if e.get("RESEARCH_SDD_KIT_STALE_VERBOSE") != "" && m.why != "" { // SENTINEL-KIT-STALE-VERBOSE
		r.deg = "verify kit-stale status=degraded reason=" + m.why
	}
	return r
}

// measurement is the outcome of the bounded git work.
type measurement struct {
	state string // "", "ok" or "stale"
	line  string
	why   string // the reason the state is unknown or partial
}

func measure(e envView, kdir string, kmax, kdays int, now func() time.Time, mtime func(string) (int64, error)) measurement {
	var m measurement
	if _, ok := findExe("git", e.get("PATH")); !ok {
		m.why = "git not found; cannot tell whether the kit is behind its upstream" // SENTINEL-KIT-STALE-NOGIT
		return m
	}
	deadline := now().Add(staleBound)
	abandoned := false
	run := func(dir string, args ...string) (string, bool) {
		left := deadline.Sub(now())
		if left <= 0 {
			abandoned = true
			return "", false
		}
		out, err := git.Runner{Env: e.environ(), Timeout: left, Now: now}.Run(dir, args...)
		if errors.Is(err, git.ErrTimeout) || errors.Is(err, git.ErrOutputCap) {
			abandoned = true
		}
		return trimNL(string(out)), err == nil
	}
	finish := func() measurement {
		if abandoned {
			return measurement{why: "git did not answer within 3s (check abandoned)"}
		}
		return m
	}

	top, ok := run(kdir, "rev-parse", "--show-toplevel")
	if !ok || top == "" {
		m.why = "kit dir is not a git checkout (tarball install?)"
		return finish()
	}
	kd, kok := physicalDir(kdir)
	t, tok := physicalDir(top)
	if !kok || !tok || (t != kd && t != filepath.Dir(kd)) {
		m.why = "kit dir sits inside an unrelated repo; its upstream is not the kit's"
		return finish()
	}
	ref, ok := run(kd, "rev-parse", "--abbrev-ref", "@{upstream}")
	fallback := false
	if !ok || ref == "" {
		if abandoned {
			return finish()
		}
		if _, ok := run(kd, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/main"); ok {
			ref, fallback = "origin/main", true
		} else {
			m.why = "no upstream ref (no @{upstream}, no origin/main); cannot tell whether the kit is behind"
			return finish()
		}
	}
	nStr, ok := run(kd, "rev-list", "--count", "HEAD.."+ref)
	n, nerr := strconv.Atoi(nStr)
	if !ok || nerr != nil || nStr == "" || strings.TrimLeft(nStr, "0123456789") != "" {
		m.why = "could not count commits behind " + ref
		return finish()
	}
	// a failed git-path lookup must not turn into "$kd/" (always present, always fresh): the whole measurement is then unknown
	fh, ok := run(kd, "rev-parse", "--git-path", "FETCH_HEAD") // SENTINEL-KIT-STALE-GITPATH
	if !ok || fh == "" {
		m.why = "could not locate FETCH_HEAD (git rev-parse --git-path failed)"
		return finish()
	}
	if !filepath.IsAbs(fh) {
		fh = kd + "/" + fh
	}
	var age int64 = -1
	switch ft, err := fhTime(fh, mtime); {
	case err == nil:
		age = (now().Unix() - ft) / 86400
		if age < 0 {
			age = 0
		}
	case !isFile(fh):
		m.why = fmt.Sprintf("no FETCH_HEAD (never fetched): age criterion skipped, judged by commit count only (behind=%d of max %d)", n, kmax)
	default:
		m.why = fmt.Sprintf("cannot read the age of the last fetch; judged by commit count only (behind=%d of max %d)", n, kmax)
	}
	if abandoned {
		return finish()
	}
	m.state = "ok"
	if n > kmax || (age >= 0 && age > int64(kdays)) { // SENTINEL-KIT-STALE-THRESHOLD
		m.state = "stale"
		m.line = staleLine(kd, e.get("HOME"), ref, fallback, n, kmax, age, kdays)
	}
	return finish()
}

// fhTime is `[ -f "$fh" ] && stat -c %Y "$fh"`: an error when the file is not a regular file or its time cannot be read.
func fhTime(fh string, mtime func(string) (int64, error)) (int64, error) {
	if !isFile(fh) {
		return 0, os.ErrNotExist
	}
	return mtime(fh)
}

// osMtime is the production mtime.
func osMtime(p string) (int64, error) {
	st, err := os.Stat(p)
	if err != nil {
		return 0, err
	}
	return st.ModTime().Unix(), nil
}

// staleLine is the one typed stale line, at most 200 characters, the fix command never cut.
func staleLine(kd, home, ref string, fallback bool, n, kmax int, age int64, kdays int) string {
	disp := kd
	if strings.HasPrefix(kd, home+"/") {
		disp = "~" + strings.TrimPrefix(kd, home)
	}
	var cmd string
	if fallback { // no @{upstream}: pull would fail
		cmd = fmt.Sprintf("git -C %s fetch && git -C %s merge --ff-only %s", disp, disp, ref)
	} else {
		cmd = fmt.Sprintf("git -C %s pull --ff-only", disp)
	}
	head := "verify kit-stale status=stale fix (no live session): " + cmd // the command comes first and is never cut
	ageS := "?"
	if age >= 0 {
		ageS = strconv.FormatInt(age, 10)
	}
	tail := fmt.Sprintf("; behind=%d (max %d) fetch_age=%sd (max %dd); local refs, may understate", n, kmax, ageS, kdays)
	room := staleWidth - utf8.RuneCountInString(head) // SENTINEL-KIT-STALE-WIDTH
	if room < 0 {
		room = 0
	}
	return head + clip(tail, room)
}
