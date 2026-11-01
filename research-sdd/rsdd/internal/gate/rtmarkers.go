package gate

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Port of the block-once marker handling of toolbelt/return-token-gate.sh: the lookup (`grep -qxF`), the append
// and _rtg_prune_markers.
//
// Known, deliberate differences: the bash visits candidate markers in locale collation order (a glob) and Go in
// byte order, which only matters between two markers with an identical mtime; RETURN_TOKEN_GATE_MARKER_* values
// with leading zeros are read as decimal (bash arithmetic would read octal).

const markerPrefix = ".rsdd-return-token-blocked-"

// markerHas is `[ -f marker ] && grep -qxF -- emitted marker`: some whole line equals emitted.
func markerHas(marker, emitted string) bool {
	st, err := os.Stat(marker)
	if err != nil || !st.Mode().IsRegular() {
		return false
	}
	b, err := os.ReadFile(marker)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(b), "\n") {
		if line == emitted {
			return true
		}
	}
	return false
}

// markerAppend is `mkdir -p dir && printf '%s\n' emitted >> marker`.
func markerAppend(dir, marker, emitted string) error {
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return err
	}
	f, err := os.OpenFile(marker, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(emitted + "\n"); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// envCount reads RETURN_TOKEN_GATE_MARKER_MAX_AGE_DAYS / _KEEP: digits only, else dflt; zeroOK says whether 0 is
// a value (the age) or means the default (the keep count).
func envCount(v string, dflt int64, zeroOK bool) int64 {
	if v == "" || strings.Trim(v, "0123456789") != "" {
		return dflt
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 1<<63 - 1
	}
	if n == 0 && !zeroOK {
		return dflt
	}
	return n
}

// pruneMarkers is _rtg_prune_markers: only regular, non-symlink files directly under dir whose whole name is
// markerPrefix plus [A-Za-z0-9._-]+ are ever touched. Markers older than maxAge whole days go first; of the rest
// only the keep newest survive, cur (the marker just written) always first. false is the bash `return 1`.
func pruneMarkers(dir string, maxAge, keep int64, cur string, now time.Time) bool {
	ents, _ := os.ReadDir(dir)
	sorted := []string{cur}
	mtime := map[string]time.Time{}
	mt := func(p string) time.Time {
		if t, ok := mtime[p]; ok {
			return t
		}
		st, err := os.Stat(p)
		if err != nil {
			return time.Time{}
		}
		mtime[p] = st.ModTime()
		return mtime[p]
	}
	for _, e := range ents {
		name := e.Name()
		f := filepath.Join(dir, name)
		if !strings.HasPrefix(name, markerPrefix) || f == cur {
			continue
		}
		if st, err := os.Lstat(f); err != nil || !st.Mode().IsRegular() {
			continue
		}
		if sfx := strings.TrimPrefix(name, markerPrefix); sfx == "" || sidSafe(sfx, false) != sfx { // RTG-PRUNE-NAME
			continue
		}
		if int64(now.Sub(mt(f))/(24*time.Hour)) > maxAge { // RTG-PRUNE-AGE
			if os.Remove(f) != nil && pathExists(f) {
				return false
			}
			continue
		}
		i := 1
		for i < len(sorted) && !mt(f).After(mt(sorted[i])) {
			i++
		}
		sorted = append(sorted, "")
		copy(sorted[i+1:], sorted[i:])
		sorted[i] = f
	}
	for i := keep; i < int64(len(sorted)); i++ { // RTG-PRUNE-CAP
		if os.Remove(sorted[i]) != nil && pathExists(sorted[i]) {
			return false
		}
	}
	return true
}

func pathExists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}
