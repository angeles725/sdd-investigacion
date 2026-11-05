package cleancheck

import (
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// evidenceDirName is the directory a campaign keeps its rollback and backup copies in.
const evidenceDirName = "_evidence"

// discoverDepth is how far below the target the discovery looks for _evidence directories (find -maxdepth 4).
const discoverDepth = 4

// scanEvidence is class (g), report-only: rollback and backup entries older than --backup-days. The states are never
// a bare zero: an explicit directory that is missing is the typed ABSENT-EVIDENCE line (`absent`); none found below
// the target is `none found`; a scan that failed is DEGRADED-EVIDENCE-SCAN (`degraded`); otherwise the counts.
func (r *run) scanEvidence() string {
	var dirs []string
	suffix := ""
	if arg := r.o.Evidence; arg != "" {
		if arg = strings.TrimSuffix(arg, "/"); arg == "" {
			arg = "/"
		}
		if !isDir(r.o.Cwd, arg) {
			r.absent(AbsentEvidence, arg, "ABSENT-EVIDENCE "+arg)
			return "absent"
		}
		dirs = []string{arg}
	} else {
		found, unreadable, ok := r.discoverEvidence()
		if !ok {
			return "degraded"
		}
		if unreadable > 0 {
			suffix = ", " + strconv.Itoa(unreadable) + " unreadable dir(s) skipped"
		}
		if len(found) == 0 {
			return "none found" + suffix
		}
		dirs = found
	}
	scanned, old, bad := 0, 0, 0
	for _, d := range dirs {
		stale, ok := r.staleBackups(d)
		if !ok {
			bad++
			continue
		}
		scanned++
		for _, p := range stale {
			r.warn("stale-backup " + p + " age=" + r.ageIn(p, 86400, "d") + " retention=" + strconv.Itoa(r.o.BackupDays) + "d")
			old++
		}
	}
	state := strconv.Itoa(scanned) + " dir(s) scanned, " + strconv.Itoa(old) + " older than " + strconv.Itoa(r.o.BackupDays) + "d"
	if bad > 0 {
		state += ", " + strconv.Itoa(bad) + " unreadable"
	}
	return state + suffix
}

// discoverEvidence finds every _evidence directory up to discoverDepth levels below the target (.git excluded),
// sorted. A directory it cannot read that is not under an _evidence directory only hides what is below it: it is
// counted and named in an INFO line. Any other read error degrades the scan (ok false).
func (r *run) discoverEvidence() (dirs []string, unreadable int, ok bool) {
	errs := walkTree(r.targetP, discoverDepth, func(p string, _ int, e entry) bool {
		if e.name == ".git" {
			return false
		}
		if e.info.IsDir() && e.name == evidenceDirName {
			dirs = append(dirs, p)
		}
		return true
	})
	sort.Strings(dirs)
	if len(errs) == 0 {
		return dirs, 0, true
	}
	infos, unreadable, fatal := classifyDiscovery(r.targetP, errs)
	for _, line := range infos {
		r.stdout(line)
	}
	if fatal {
		r.degrade(DegradedEvidence, "DEGRADED-EVIDENCE-SCAN find for _evidence directories failed under "+r.targetP+": "+oneLine(strings.Join(findStderr(errs), "\n")), "evidence scan failed")
		return nil, 0, false
	}
	return dirs, unreadable, true
}

// classifyDiscovery sorts the read errors of the _evidence discovery, in order. A permission error on a directory that
// is not under an _evidence directory (judged on the path below the target, so a target whose own path holds
// _evidence does not count) only hides what is below it: it becomes an INFO line and a count. Any other error, or a
// permission error under an _evidence directory, makes the scan fatal; the INFO lines before it were already due.
func classifyDiscovery(target string, errs []findError) (infos []string, unreadable int, fatal bool) {
	for _, e := range errs {
		if !e.denied || underEvidence(strings.TrimPrefix(e.path, target+"/")) {
			return infos, unreadable, true
		}
		unreadable++
		infos = append(infos, "INFO evidence-discovery skipped unreadable directory (evidence dirs below it, if any, are not scanned): "+e.line())
	}
	return infos, unreadable, false
}

// underEvidence reports whether _evidence is a whole component of the path.
func underEvidence(rel string) bool {
	return strings.Contains("/"+rel+"/", "/"+evidenceDirName+"/")
}

// staleBackups lists, sorted, the entries 1 or 2 levels below dir whose name holds rollback or backup (any case) and
// whose mtime is older than the retention age. A matching directory is listed once: its contents are not.
func (r *run) staleBackups(dir string) ([]string, bool) {
	start := dir
	if p, err := filepath.EvalSymlinks(dir); err == nil {
		start = p // a symlinked evidence directory is read through, not mistaken for an empty one
	}
	var stale []string
	errs := walkTree(start, 2, func(p string, _ int, e entry) bool {
		name := asciiFold(e.name)
		if (strings.Contains(name, "rollback") || strings.Contains(name, "backup")) && olderThan(r.now, e.info.ModTime(), int64(r.o.BackupDays)*1440) {
			stale = append(stale, join(dir, strings.TrimPrefix(p, start+"/")))
			return false
		}
		return true
	})
	if len(errs) > 0 {
		r.stderr(strings.Join(findStderr(errs), "\n"))
		r.degrade(DegradedEvidence, "DEGRADED-EVIDENCE-SCAN find failed or was truncated under "+dir, "evidence scan failed")
		return nil, false
	}
	sort.Strings(stale)
	return stale, true
}

// asciiFold makes only the ASCII capitals lower case: -iname folds ASCII, so U+212A is not a k.
func asciiFold(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}
