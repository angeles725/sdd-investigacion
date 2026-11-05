package cleancheck

import (
	"os"
	"sort"
	"strconv"
	"strings"
)

// scratchExts are the script extensions class (d) looks at.
var scratchExts = []string{".sh", ".ps1", ".py", ".java", ".js", ".rb", ".pl", ".bat", ".cmd", ".groovy", ".kts"}

func isScript(base string) bool {
	for _, e := range scratchExts {
		if strings.HasSuffix(base, e) {
			return true
		}
	}
	return false
}

// settleScratchpad resolves the configured scratchpad: physical when it exists, as given (one trailing slash
// stripped) when it does not. A lone "/" stays "/" (the script reduced it to nothing and then reported the scratchpad
// as not set).
func (r *run) settleScratchpad() {
	s := r.o.Scratchpad
	if s == "" {
		return
	}
	if t := strings.TrimSuffix(s, "/"); t != "" {
		s = t
	}
	if p, err := physical(r.o.Cwd, s); err == nil && isDir(r.o.Cwd, s) {
		s = p
	}
	r.scratchP = s
}

func isDir(cwd, p string) bool {
	if !strings.HasPrefix(p, "/") {
		p = cwd + "/" + p
	}
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// scanScratchpad is classes (c) and (d) and the scratchpad's summary field. Not configured is `not set`, configured
// but missing is the typed ABSENT-SCRATCHPAD line and `absent`, otherwise the counts.
func (r *run) scanScratchpad() (state string, ok bool) {
	if r.scratchP == "" {
		return "not set", true
	}
	if !isDir(r.o.Cwd, r.scratchP) {
		r.absent(AbsentScratchpad, r.scratchP, "ABSENT-SCRATCHPAD "+r.scratchP)
		return "absent", true
	}
	files, ok := r.scratchFiles()
	if !ok {
		return "", false
	}
	blocks, missing, ok := r.listBlocks()
	if !ok {
		return "", false
	}
	probes, ok := r.readProbes()
	if !ok {
		return "", false
	}
	cites := &blockReader{r: r, blocks: blocks}
	preserved := 0
	for _, f := range files {
		base := f[strings.LastIndex(f, "/")+1:]
		citer, ok := cites.firstCiting(base)
		if !ok {
			return "", false
		}
		if citer != "" {
			if probes.hasCopy(f) {
				preserved++
			} else {
				r.finding("UNPRESERVED-ARTIFACT " + f + " cited by " + citer)
			}
		}
		if isScript(base) && !probes.manifested[base] {
			r.finding("UNMANIFESTED-SCRIPT " + f)
		}
	}
	return strconv.Itoa(len(files)) + " file(s), blocks-missing-on-disk: " + strconv.Itoa(missing) + ", preserved-copies: " + strconv.Itoa(preserved), true
}

// scratchFiles lists the regular files of the scratchpad, sorted bytewise. The directory is live: an entry that
// vanishes mid-walk is benign, any other read error ends the run.
func (r *run) scratchFiles() ([]string, bool) {
	var files []string
	errs := walkTree(r.scratchP, -1, func(p string, _ int, e entry) bool {
		if e.info.Mode().IsRegular() {
			files = append(files, p)
		}
		return true
	})
	if len(errs) > 0 {
		r.stderr(strings.Join(findStderr(errs), "\n"))
		return nil, r.refuse("find failed or was truncated in scratchpad " + r.scratchP)
	}
	sort.Strings(files)
	return files, true
}
