package formats

import (
	"bytes"
	"testing"
)

var teethLimits = storedLimits{
	maxMetadata: 1 << 20, maxEntries: 1000, maxPath: 4096, maxDepth: 64,
	maxEntry: 1 << 30, maxTotal: 1 << 30, maxReport: 1 << 24,
}

var teethStoredOpts = zipOpts{madeBy: 3<<8 | 20, dosTime: 1, dosDate: 0x5821}

const (
	teethReg = uint32(0o100644) << 16
	teethDir = uint32(0o40755)<<16 | 0x10
)

func teethInspect(data []byte, lim storedLimits) ([]storedEntry, error) {
	_, recs, err := inspectStored(bytes.NewReader(data), int64(len(data)), lim)
	return recs, err
}

func TestStageChunk(t *testing.T) {
	for name, c := range map[string]struct{ buf, limit, total, want int64 }{
		"one past the cap from the start": {1 << 20, 10, 0, 11},
		"remaining plus one":              {1 << 20, 10, 4, 7},
		"at the cap: just one more byte":  {1 << 20, 10, 10, 1},
		"the buffer is the smaller":       {5, 10, 0, 5},
		"large cap, full buffer":          {1 << 20, 1 << 40, 1 << 20, 1 << 20},
	} {
		if got := stageChunk(c.buf, c.limit, c.total); got != c.want {
			t.Errorf("%s: stageChunk(%d, %d, %d) = %d, want %d", name, c.buf, c.limit, c.total, got, c.want)
		}
	}
}

func TestIsSpecialRuneBounds(t *testing.T) {
	for r, want := range map[rune]bool{0: true, 1: true, 31: true, 32: false, 'a': false, 126: false, 127: true, 128: false} {
		if got := isSpecialRune(r); got != want {
			t.Errorf("isSpecialRune(%d) = %v, want %v", r, got, want)
		}
	}
}

func TestStoredPathUnsafeSpecialAtAnyIndex(t *testing.T) {
	for name, c := range map[string]struct {
		path string
		want bool
	}{
		"control first":           {"\x01a", true},
		"control last":            {"a\x01", true},
		"del first":               {"\x7fa", true},
		"del inside":              {"a\x7fb", true},
		"space is fine":           {" a", false},
		"tilde is fine":           {"~a", false},
		"plain":                   {"dir/file.txt", false},
		"control in a later part": {"dir/\x1fx", true},
	} {
		if got := storedPathUnsafe(c.path, c.path, splitPlain(c.path)); got != c.want {
			t.Errorf("%s: storedPathUnsafe(%q) = %v, want %v", name, c.path, got, c.want)
		}
	}
}

func splitPlain(p string) []string {
	var parts []string
	last := 0
	for i := 0; i < len(p); i++ {
		if p[i] == '/' {
			parts = append(parts, p[last:i])
			last = i + 1
		}
	}
	return append(parts, p[last:])
}

func TestInspectStoredLimitBoundaries(t *testing.T) {
	two := buildZip([]zfx{
		{name: []byte("abcd"), payload: []byte("123"), attrs: teethReg},
		{name: []byte("efg"), payload: []byte("4567"), attrs: teethReg},
	}, teethStoredOpts)
	zero := buildZip([]zfx{{name: []byte("z"), attrs: teethReg}}, teethStoredOpts)
	with := func(mut func(*storedLimits)) storedLimits {
		l := teethLimits
		mut(&l)
		return l
	}
	for name, c := range map[string]struct {
		data []byte
		lim  storedLimits
		want string
	}{
		"path at the cap":        {two, with(func(l *storedLimits) { l.maxPath = 4 }), ""},
		"path over the cap":      {two, with(func(l *storedLimits) { l.maxPath = 3 }), "entry path exceeds max-path-bytes"},
		"entry at the cap":       {two, with(func(l *storedLimits) { l.maxEntry = 4 }), ""},
		"entry over the cap":     {two, with(func(l *storedLimits) { l.maxEntry = 3 }), "entry exceeds max-entry-bytes"},
		"zero entry, zero cap":   {zero, with(func(l *storedLimits) { l.maxEntry = 0 }), ""},
		"total at the cap":       {two, with(func(l *storedLimits) { l.maxTotal = 7 }), ""},
		"total over the cap":     {two, with(func(l *storedLimits) { l.maxTotal = 6 }), "extracted bytes exceed max-total-bytes"},
		"zero total, zero cap":   {zero, with(func(l *storedLimits) { l.maxTotal = 0 }), ""},
		"first entry over total": {two, with(func(l *storedLimits) { l.maxTotal = 2 }), "extracted bytes exceed max-total-bytes"},
	} {
		_, err := teethInspect(c.data, c.lim)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: error %q, want %q", name, got, c.want)
		}
	}
}

func TestInspectStoredAncestorConflicts(t *testing.T) {
	file := func(name string) zfx { return zfx{name: []byte(name), payload: []byte("x"), attrs: teethReg} }
	dir := func(name string) zfx { return zfx{name: []byte(name), attrs: teethDir} }
	const conflict = "duplicate or ancestor path conflict"
	for name, c := range map[string]struct {
		entries []zfx
		want    string
	}{
		"file then file inside it":                   {[]zfx{file("a"), file("a/b")}, conflict},
		"file inside then the file itself":           {[]zfx{file("a/b"), file("a")}, conflict},
		"deep file then its parent as a file":        {[]zfx{file("a/b/c"), file("a/b")}, conflict},
		"deep file then its grandparent file":        {[]zfx{file("a/b/c"), file("a")}, conflict},
		"file inside then the directory":             {[]zfx{file("a/b"), dir("a/")}, ""},
		"deep file then the intermediate dir":        {[]zfx{file("a/b/c"), dir("a/b/")}, ""},
		"siblings":                                   {[]zfx{file("a/b"), file("a/c")}, ""},
		"directory then file inside":                 {[]zfx{dir("a/"), file("a/b")}, ""},
		"directory then same file name":              {[]zfx{dir("a/"), file("a")}, conflict},
		"same directory twice":                       {[]zfx{dir("a/"), dir("a/")}, conflict},
		"deep file then ancestor file in the middle": {[]zfx{file("a/b/c"), file("x"), file("a/b")}, conflict},
	} {
		data := buildZip(c.entries, teethStoredOpts)
		_, err := teethInspect(data, teethLimits)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: error %q, want %q", name, got, c.want)
		}
	}
}

// The central directory may list entries in any order; the overlap check works on payload ranges ordered by
// position, so a reversed directory over disjoint payloads must still be admitted.
func TestInspectStoredAcceptsAnyDirectoryOrder(t *testing.T) {
	data := buildZip([]zfx{
		{name: []byte("a"), payload: []byte("first"), attrs: teethReg},
		{name: []byte("b"), payload: []byte("second"), attrs: teethReg},
		{name: []byte("c"), payload: []byte("third"), attrs: teethReg},
	}, teethStoredOpts)
	cd := bytes.Index(data, []byte("PK\x01\x02"))
	const rec = 46 + 1
	records := [][]byte{data[cd : cd+rec], data[cd+rec : cd+2*rec], data[cd+2*rec : cd+3*rec]}
	order := [][]int{{2, 1, 0}, {1, 2, 0}, {2, 0, 1}, {1, 0, 2}}
	for _, o := range order {
		swapped := append([]byte(nil), data[:cd]...)
		for _, i := range o {
			swapped = append(swapped, records[i]...)
		}
		swapped = append(swapped, data[cd+3*rec:]...)
		recs, err := teethInspect(swapped, teethLimits)
		if err != nil {
			t.Errorf("order %v: %v", o, err)
			continue
		}
		var names string
		for _, r := range recs {
			names += r.path
		}
		if want := string([]byte{"abc"[o[0]], "abc"[o[1]], "abc"[o[2]]}); names != want {
			t.Errorf("order %v: records %q, want %q", o, names, want)
		}
	}
}
