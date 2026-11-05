package cleancheck

import (
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"
)

// olderThan is find's `-mmin +n`: the entry was modified more than limitMinutes before the start of the run. GNU
// find compares exactly (nanoseconds), so 3 seconds old is older than +0.
func olderThan(now time.Time, mtime time.Time, limitMinutes int64) bool {
	return now.Sub(mtime) > time.Duration(limitMinutes)*time.Minute
}

// ageIn is `$(( (now - mtime) / unit ))` in whole units, with the unit's suffix, or "unknown" when the entry's own
// mtime cannot be read (it vanished since it was listed).
func (r *run) ageIn(path string, unitSeconds int64, suffix string) string {
	info, err := r.lstat(path)
	if err != nil {
		return "unknown"
	}
	return strconv.FormatInt((r.now.Unix()-info.ModTime().Unix())/unitSeconds, 10) + suffix
}

// scanStaleTmp is class (b): the direct children of the tmp directory named tmp.*, owned by the configured uid and
// older than the stale age, sorted bytewise, except what lies in the scratchpad.
func (r *run) scanStaleTmp() bool {
	r.now = r.o.Now()
	ents, err := listDir(r.tmpP)
	if err != nil {
		r.stderr(newFindError(r.tmpP, err).line())
		return r.refuse("find failed or was truncated in " + r.tmp)
	}
	var paths []string
	for _, e := range ents {
		if !strings.HasPrefix(e.name, "tmp.") || !r.ownedBy(e.info) || !olderThan(r.now, e.info.ModTime(), int64(r.o.StaleHours)*60) {
			continue
		}
		paths = append(paths, join(r.tmpP, e.name))
	}
	sort.Strings(paths)
	for _, p := range paths {
		if r.inScratch(p) {
			continue
		}
		r.finding("GARBAGE stale-tmp " + r.tmp + "/" + p[strings.LastIndex(p, "/")+1:] + " age=" + r.ageIn(p, 3600, "h"))
	}
	return true
}

// ownedBy is find's -uid: the entry's own owner (a symlink's, not its target's) is the configured uid.
func (r *run) ownedBy(info fs.FileInfo) bool {
	uid, ok := ownerOf(info)
	return ok && uid == r.uid
}
