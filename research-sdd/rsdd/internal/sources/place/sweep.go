package place

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// partMarker mirrors download.PartMarker (the part file name is <name>.fetchdoc-part.<pid>); it is repeated here
// only because the sweep must recognise the marker without importing the downloader.
const partMarker = ".fetchdoc-part."

// SweepStale removes "*.fetchdoc-part.<pid>" files in dir whose pid is positively dead: a SIGKILLed run cannot
// run its cleanup, and verify-sources would keep reporting the debris as "unregistered on disk". It never touches
// a file registered in SOURCES.md, nor the part file of a live pid. alive reports a pid's liveness (nil: the
// default, see Alive).
func (p *Placer) SweepStale(dir string, alive func(pid string) bool) {
	if alive == nil {
		alive = Alive
	}
	ents, err := os.ReadDir(dir) // sorted by name, like the shell glob in the C locale
	if err != nil {
		return
	}
	names := make([]string, 0, len(ents))
	for _, e := range ents {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		pid, ok := partPid(name)
		if !ok {
			continue
		}
		f := dir + "/" + name                 // not filepath.Join: the File cell keeps the path as typed
		if _, err := os.Stat(f); err != nil { // [ -e ]: a dangling symlink is not debris of ours
			continue
		}
		if has, _ := srcregistry.Has(p.SDir, p.Rel(f), ""); has {
			continue // registered evidence is never debris
		}
		if !alive(pid) {
			_ = os.Remove(f)
			fmt.Fprintf(p.Err, "fetch-doc: removed stale part file from dead pid %s: %s\n", pid, name)
		}
	}
}

// partPid is the pid of a part file name: the digits after the LAST marker; a hidden name (the shell glob does
// not match it) or a non-numeric tail is not a part file.
func partPid(name string) (string, bool) {
	if strings.HasPrefix(name, ".") || !strings.Contains(name, partMarker) {
		return "", false
	}
	pid := name[strings.LastIndex(name, partMarker)+len(partMarker):]
	if pid == "" || strings.Trim(pid, "0123456789") != "" {
		return "", false
	}
	return pid, true
}

// Alive is positive liveness: the pid answers signal 0 (EPERM, another user's process, still means alive).
// An unparsable pid is assumed alive: debris is only removed on proof.
func Alive(pid string) bool {
	n, err := strconv.Atoi(pid)
	if err != nil {
		return true
	}
	err = syscall.Kill(n, 0)
	return err == nil || err == syscall.EPERM
}
