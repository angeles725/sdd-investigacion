package classfile

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Teeth for jar.go: the exported surface java-corroboration.v1 reads facts and archive entries through.

func openJar(t *testing.T, b []byte) *Jar {
	t.Helper()
	p := filepath.Join(t.TempDir(), "x.jar")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	j, err := OpenJar(p)
	if err != nil {
		t.Fatalf("OpenJar: %v", err)
	}
	t.Cleanup(func() { _ = j.Close() })
	return j
}

func TestReadFactsReasonTokens(t *testing.T) {
	c := buildClass(classOpts{major: 52, lvt: true})
	cases := []struct {
		name   string
		data   []byte
		major  *int
		lvt    *bool
		reason string
	}{
		{"empty", nil, nil, nil, "truncated-header"},
		{"seven bytes", c[:7], nil, nil, "truncated-header"},
		{"bad magic", append([]byte{0xde, 0xad, 0xbe, 0xef}, c[4:]...), nil, nil, "bad-magic"},
		{"header only", c[:8], ptr(52), nil, "truncated-body"},
		{"cut inside the pool", c[:20], ptr(52), nil, "truncated-body"},
		{"unknown pool tag", buildClass(classOpts{major: 52, extraPool: [][]byte{{2, 0, 0, 0, 0}}}), ptr(52), nil, "bad-constant-pool-tag"},
		{"tag 13", buildClass(classOpts{major: 52, extraPool: [][]byte{{13, 0, 0, 0, 0}}}), ptr(52), nil, "bad-constant-pool-tag"},
		{"cut in the code attribute", buildClass(classOpts{major: 52, methodAttr: cat(u16(1), attr(7, []byte{0, 1, 0, 1, 0, 0, 0, 9, 0xb1}))}), ptr(52), nil, "truncated-body"},
		{"whole", c, ptr(52), ptr2(true), ""},
		{"no lvt", buildClass(classOpts{major: 65}), ptr(65), ptr2(false), ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ReadFacts(tc.data)
			if !reflect.DeepEqual(got.Major, tc.major) || !reflect.DeepEqual(got.LVT, tc.lvt) || got.Reason != tc.reason {
				t.Fatalf("ReadFacts = %+v, want major %v lvt %v reason %q", got, deref(tc.major), tc.lvt, tc.reason)
			}
			if tc.major != nil && (got.ResugarRisk == nil || *got.ResugarRisk != (*tc.major >= ResugarMinMajor)) {
				t.Errorf("resugar_risk = %v for major %d", got.ResugarRisk, *tc.major)
			}
			if tc.major == nil && got.ResugarRisk != nil {
				t.Error("an unreadable header has no resugar_risk")
			}
		})
	}
}

func ptr(v int) *int    { return &v }
func ptr2(v bool) *bool { return &v }
func deref(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

func TestFactMapUsesNullsAndTheReportKeys(t *testing.T) {
	whole := ReadFacts(buildClass(classOpts{major: 61}))
	if got := whole.Map("a/B.class"); !reflect.DeepEqual(got, map[string]any{
		"entry": "a/B.class", "major_version": 61, "has_LocalVariableTable": false, "resugar_risk": true, "reason": nil}) {
		t.Errorf("whole = %v", got)
	}
	broken := ReadFacts([]byte{1, 2})
	if got := broken.Map("x"); !reflect.DeepEqual(got, map[string]any{
		"entry": "x", "major_version": nil, "has_LocalVariableTable": nil, "resugar_risk": nil, "reason": "truncated-header"}) {
		t.Errorf("broken = %v", got)
	}
}

func TestSummarizeAggregatesLikeSummarizeFacts(t *testing.T) {
	lvt := ReadFacts(buildClass(classOpts{major: 52, lvt: true}))
	plain := ReadFacts(buildClass(classOpts{major: 65}))
	partial := ReadFacts(buildClass(classOpts{major: 55, extraPool: [][]byte{{2, 0}}}))
	unreadable := ReadFacts(nil)
	cases := []struct {
		name string
		in   []Fact
		want map[string]any
	}{
		{"none", nil, map[string]any{"classes": 0, "major_versions": []int{}, "lvt": "unknown", "resugar_risk_classes": 0, "unreadable_classes": 0, "partial_classes": 0}},
		{"yes", []Fact{lvt, lvt}, map[string]any{"classes": 2, "major_versions": []int{52}, "lvt": "yes", "resugar_risk_classes": 0, "unreadable_classes": 0, "partial_classes": 0}},
		{"no", []Fact{plain}, map[string]any{"classes": 1, "major_versions": []int{65}, "lvt": "no", "resugar_risk_classes": 1, "unreadable_classes": 0, "partial_classes": 0}},
		{"mixed with broken ones", []Fact{lvt, plain, partial, unreadable}, map[string]any{"classes": 4, "major_versions": []int{52, 55, 65}, "lvt": "mixed", "resugar_risk_classes": 2, "unreadable_classes": 1, "partial_classes": 1}},
		{"only unreadable", []Fact{unreadable}, map[string]any{"classes": 1, "major_versions": []int{}, "lvt": "unknown", "resugar_risk_classes": 0, "unreadable_classes": 1, "partial_classes": 0}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Summarize(c.in); !reflect.DeepEqual(got, c.want) {
				t.Fatalf("Summarize = %v, want %v", got, c.want)
			}
		})
	}
}

func TestEntriesExposeNameSizeModeAndKind(t *testing.T) {
	good := buildClass(classOpts{major: 52})
	link := ent("l.class", []byte("/etc/passwd"), 0)
	link.extAttr = (0o120777) << 16
	file := ent("f.class", good, 8)
	file.extAttr = (0o100644) << 16
	dir := ent("d/", nil, 0)
	j := openJar(t, buildZip([]zent{file, dir, link}, zopts{}))
	got := j.Entries()
	want := []EntryInfo{
		{Name: "f.class", Size: uint64(len(good)), Mode: 0o100644},
		{Name: "d/", Size: 0, Mode: 0},
		{Name: "l.class", Size: 11, Mode: 0o120777},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Entries = %+v, want %+v", got, want)
	}
	if got[0].IsDir() || !got[1].IsDir() || got[0].IsSymlink() || got[1].IsSymlink() || !got[2].IsSymlink() {
		t.Errorf("kinds wrong: %+v", got)
	}
}

func TestOpenJarDistinguishesNotAnArchiveFromADamagedOne(t *testing.T) {
	dir := t.TempDir()
	plain := filepath.Join(dir, "plain")
	if err := os.WriteFile(plain, []byte("not a zip"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenJar(plain); !errors.Is(err, ErrNotArchive) {
		t.Errorf("plain file: %v", err)
	}
	if _, err := OpenJar(filepath.Join(dir, "missing")); !errors.Is(err, ErrNotArchive) {
		t.Errorf("missing file: %v", err)
	}
	damaged := buildZip([]zent{ent("a.class", []byte("x"), 0)}, zopts{})
	damaged[bytesIndex(damaged, "PK\x01\x02")+1] = 'X' // the central directory entry loses its signature
	p := filepath.Join(dir, "damaged.jar")
	if err := os.WriteFile(p, damaged, 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := OpenJar(p)
	if err == nil || errors.Is(err, ErrNotArchive) || PyClass(err) != "BadZipFile" {
		t.Errorf("damaged directory: err=%v class=%q, want BadZipFile", err, PyClass(err))
	}
}

func bytesIndex(b []byte, sig string) int {
	for i := range b {
		if string(b[i:min(i+len(sig), len(b))]) == sig {
			return i
		}
	}
	return -1
}

func TestTestZipReportsTheFirstBadCRCAndPropagatesOtherClasses(t *testing.T) {
	c := buildClass(classOpts{major: 52})
	badCRC := ent("crc.class", c, 0)
	badCRC.crc ^= 1
	if name, err := openJar(t, buildZip([]zent{ent("ok.class", c, 8), badCRC, ent("later.class", c, 0)}, zopts{})).TestZip(); err != nil || name != "crc.class" {
		t.Errorf("bad CRC: %q, %v", name, err)
	}
	if name, err := openJar(t, buildZip([]zent{ent("a.class", c, 8), ent("b.class", c, 0)}, zopts{})).TestZip(); err != nil || name != "" {
		t.Errorf("intact: %q, %v", name, err)
	}
	broken := ent("z.class", c, 8)
	broken.comp = append([]byte{0x07, 0xff}, broken.comp[2:]...) // a reserved deflate block type
	if _, err := openJar(t, buildZip([]zent{broken}, zopts{})).TestZip(); PyClass(err) != "error" {
		t.Errorf("damaged deflate stream: class %q (%v), want zlib's \"error\"", PyClass(err), err)
	}
	trunc := ent("t.class", c, 0)
	trunc.csize = uint32(len(c) + 400) // declares more data than the file holds
	if name, err := openJar(t, buildZip([]zent{trunc}, zopts{})).TestZip(); err != nil || name != "t.class" {
		t.Errorf("an entry that overlaps the central directory is BadZipFile, reported by name: %q, %v", name, err)
	}
	enc := ent("e.class", c, 0)
	enc.cflags, enc.lflags = flagEncrypted, flagEncrypted
	if _, err := openJar(t, buildZip([]zent{enc}, zopts{})).TestZip(); PyClass(err) != "RuntimeError" {
		t.Errorf("encrypted entry: class %q, want RuntimeError", PyClass(err))
	}
	method := ent("m.class", c, 0)
	method.method = 99
	if _, err := openJar(t, buildZip([]zent{method}, zopts{})).TestZip(); PyClass(err) != "NotImplementedError" {
		t.Errorf("unknown method: class %q, want NotImplementedError", PyClass(err))
	}
	negative := ent("n.class", c, 0)
	// The end record claims the directory starts 100 bytes later than it does: every header offset shifts by -100.
	shift := func(rec []byte) { binary.LittleEndian.PutUint32(rec[16:], binary.LittleEndian.Uint32(rec[16:])+100) }
	if _, err := openJar(t, buildZip([]zent{negative}, zopts{eocdMut: shift})).TestZip(); PyClass(err) != "OSError" {
		t.Errorf("a negative header offset is a seek error: class %q", PyClass(err))
	}
}

func TestJarFactsGivesReasonsPerEntryFailure(t *testing.T) {
	c := buildClass(classOpts{major: 61, lvt: true})
	crc := ent("crc.class", c, 0)
	crc.crc ^= 1
	enc := ent("enc.class", c, 0)
	enc.cflags, enc.lflags = flagEncrypted, flagEncrypted
	j := openJar(t, buildZip([]zent{ent("ok.class", c, 8), crc, enc}, zopts{}))
	for name, want := range map[string]string{"ok.class": "", "crc.class": "corrupt-entry", "enc.class": "unreadable-entry", "absent.class": "unreadable-entry"} {
		f, err := j.Facts(name, 1<<20)
		if err != nil || f.Reason != want {
			t.Errorf("%s: %+v, %v; want reason %q", name, f, err, want)
		}
	}
	if f, _ := j.Facts("ok.class", uint64(len(c))-1); f.Reason != "entry-too-large" || f.Major != nil {
		t.Errorf("over the per-class limit: %+v", f)
	}
	if f, _ := j.Facts("ok.class", uint64(len(c))); f.Reason != "" || f.Major == nil || *f.Major != 61 {
		t.Errorf("at the per-class limit: %+v", f)
	}
}

func TestJarFactsOfANonUTF8NameCrashesLikeTheScript(t *testing.T) {
	e := ent("x", buildClass(classOpts{major: 52}), 0)
	e.name, e.lname = []byte{0xff, 0xfe}, []byte{0xff, 0xfe}
	e.cflags, e.lflags = flagUTF8Name, flagUTF8Name
	p := filepath.Join(t.TempDir(), "x.jar")
	if err := os.WriteFile(p, buildZip([]zent{e}, zopts{}), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenJar(p); !errors.Is(err, ErrCrash) {
		t.Fatalf("OpenJar = %v, want ErrCrash", err)
	}
}
